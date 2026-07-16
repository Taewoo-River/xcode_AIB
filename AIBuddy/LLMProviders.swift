import Foundation

// Port of server/llm.py. Each provider streams LLMEvents:
//   .text(delta)              — visible text as it arrives
//   .toolCalls([ToolCallReq]) — at most once, at the end of a round

// ------------------------------------------------------------------ shared plumbing

private func makeStream(_ run: @escaping (AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws -> Void) -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await run(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func postJSON(url: URL, body: [String: Any], headers: [String: String], timeout: TimeInterval = 600) throws -> URLRequest {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    return req
}

private func openBytes(_ req: URLRequest, providerName: String) async throws -> URLSession.AsyncBytes {
    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if status != 200 {
        var body = ""
        for try await line in bytes.lines {
            body += line
            if body.count > 600 { break }
        }
        throw BuddyError("\(providerName) error \(status): \(String(body.prefix(300)))")
    }
    return bytes
}

private func parseJSONLine(_ line: String) -> [String: Any] {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
    return jdict(obj)
}

/// OpenAI-style function specs (also accepted by Ollama).
private func openAITools(_ tools: [ToolSpec]) -> [[String: Any]] {
    tools.map {
        [
            "type": "function",
            "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]
        ]
    }
}

private func newCallId() -> String { "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8) }

// ------------------------------------------------------------------ OpenAI-compatible
// Used for Google Gemini and OpenAI — both speak the chat-completions dialect.

final class OpenAICompatProvider: LLMProvider {
    let name: String
    let baseURL: String
    let apiKey: String
    let model: String
    let vision: Bool
    let handlesToolsInternally = false

    init(name: String, baseURL: String, apiKey: String, model: String, vision: Bool) {
        self.name = name
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.model = model
        self.vision = vision
    }

    private func convert(_ messages: [LLMMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            if m.role == "tool" {
                out.append(["role": "tool", "tool_call_id": m.toolCallId, "content": m.content])
            } else if m.role == "assistant" && !m.toolCalls.isEmpty {
                var msg: [String: Any] = ["role": "assistant", "tool_calls": m.toolCalls.map { c -> [String: Any] in
                    let argsData = (try? JSONSerialization.data(withJSONObject: c.arguments)) ?? Data("{}".utf8)
                    return [
                        "id": c.id,
                        "type": "function",
                        "function": ["name": c.name, "arguments": String(data: argsData, encoding: .utf8) ?? "{}"]
                    ]
                }]
                if !m.content.isEmpty { msg["content"] = m.content }
                out.append(msg)
            } else if !m.images.isEmpty {
                var parts: [[String: Any]] = [["type": "text", "text": m.content]]
                for b64 in m.images {
                    parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]])
                }
                out.append(["role": m.role, "content": parts])
            } else {
                out.append(["role": m.role, "content": m.content])
            }
        }
        return out
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        let name = self.name
        return makeStream { cont in
            var body: [String: Any] = ["model": self.model, "messages": self.convert(messages), "stream": true]
            if !tools.isEmpty { body["tools"] = openAITools(tools) }
            let req = try postJSON(
                url: URL(string: self.baseURL + "/chat/completions")!,
                body: body,
                headers: ["Authorization": "Bearer \(self.apiKey)"]
            )
            let bytes = try await openBytes(req, providerName: name)

            var pending: [Int: (id: String, name: String, args: String)] = [:]
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                let obj = parseJSONLine(payload)
                guard let choice = jarr(obj["choices"]).first else { continue }
                let delta = jdict(choice["delta"])
                let text = jstr(delta["content"])
                if !text.isEmpty { cont.yield(.text(text)) }
                for tc in jarr(delta["tool_calls"]) {
                    let idx = tc["index"] as? Int ?? pending.count
                    var entry = pending[idx] ?? (id: "", name: "", args: "")
                    let id = jstr(tc["id"])
                    if !id.isEmpty { entry.id = id }
                    let fn = jdict(tc["function"])
                    entry.name += jstr(fn["name"])
                    entry.args += jstr(fn["arguments"])
                    pending[idx] = entry
                }
            }
            if !pending.isEmpty {
                let calls = pending.keys.sorted().map { idx -> ToolCallReq in
                    let e = pending[idx]!
                    let args = (e.args.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
                    return ToolCallReq(id: e.id.isEmpty ? newCallId() : e.id, name: e.name, arguments: args)
                }
                cont.yield(.toolCalls(calls))
            }
        }
    }
}

// ------------------------------------------------------------------ Ollama native API (over Wi-Fi to your PC)
// Supports keep_alive (pin model in VRAM), think on/off, images, and tools.

final class OllamaNativeProvider: LLMProvider {
    let base: String            // e.g. http://192.168.0.2:11434
    let model: String
    let vision: Bool
    let think: Bool
    let keepAlive: Bool
    let handlesToolsInternally = false

    static var capsCache: (time: Date, base: String, caps: [String: Set<String>])?

    init(baseURL: String, model: String, vision: Bool, think: Bool, keepAlive: Bool) {
        var b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b = String(b.dropLast()) }
        if b.hasSuffix("/v1") { b = String(b.dropLast(3)) }
        self.base = b.isEmpty ? "http://localhost:11434" : b
        self.model = model
        self.vision = vision
        self.think = think
        self.keepAlive = keepAlive
    }

    /// {model: {"vision","tools","thinking",...}} — cached for 60 s.
    static func capabilities(base: String) async -> [String: Set<String>] {
        if let c = capsCache, c.base == base, Date().timeIntervalSince(c.time) < 60 { return c.caps }
        guard let url = URL(string: base + "/api/tags") else { return [:] }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "GET"
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return capsCache?.caps ?? [:]
        }
        var caps: [String: Set<String>] = [:]
        for m in jarr(jdict(obj)["models"]) {
            caps[jstr(m["name"])] = Set((m["capabilities"] as? [String]) ?? [])
        }
        capsCache = (Date(), base, caps)
        return caps
    }

    static func listModels(base: String) async throws -> [(name: String, caps: Set<String>)] {
        guard let url = URL(string: _normalize(base) + "/api/tags") else { throw BuddyError("Bad Ollama URL.") }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw BuddyError("Unexpected reply from Ollama.") }
        return jarr(jdict(obj)["models"]).map { (jstr($0["name"]), Set(($0["capabilities"] as? [String]) ?? [])) }
    }

    static func _normalize(_ baseURL: String) -> String {
        var b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b = String(b.dropLast()) }
        if b.hasSuffix("/v1") { b = String(b.dropLast(3)) }
        return b
    }

    private func convert(_ messages: [LLMMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            if m.role == "tool" {
                out.append(["role": "tool", "content": m.content, "tool_name": m.toolName])
                continue
            }
            var msg: [String: Any] = ["role": m.role, "content": m.content]
            if !m.images.isEmpty { msg["images"] = m.images }
            if m.role == "assistant" && !m.toolCalls.isEmpty {
                msg["tool_calls"] = m.toolCalls.map { ["function": ["name": $0.name, "arguments": $0.arguments]] }
            }
            out.append(msg)
        }
        return out
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        makeStream { cont in
            var body: [String: Any] = [
                "model": self.model,
                "messages": self.convert(messages),
                "stream": true,
                "keep_alive": self.keepAlive ? (-1 as Any) : ("5m" as Any)
            ]
            if !tools.isEmpty { body["tools"] = openAITools(tools) }
            // Only send `think` when the model supports it — Ollama rejects it otherwise.
            let caps = await Self.capabilities(base: self.base)
            if caps[self.model]?.contains("thinking") == true { body["think"] = self.think }

            let req = try postJSON(url: URL(string: self.base + "/api/chat")!, body: body, headers: [:])
            let bytes = try await openBytes(req, providerName: "Ollama")

            var calls: [ToolCallReq] = []
            for try await line in bytes.lines {
                let obj = parseJSONLine(line)
                if obj.isEmpty { continue }
                if let err = obj["error"] as? String { throw BuddyError("Ollama: \(err)") }
                let msg = jdict(obj["message"])
                let text = jstr(msg["content"])
                if !text.isEmpty { cont.yield(.text(text)) }
                for tc in jarr(msg["tool_calls"]) {
                    let fn = jdict(tc["function"])
                    var args = jdict(fn["arguments"])
                    if args.isEmpty, let s = fn["arguments"] as? String, let d = s.data(using: .utf8) {
                        args = jdict(try? JSONSerialization.jsonObject(with: d))
                    }
                    calls.append(ToolCallReq(id: newCallId(), name: jstr(fn["name"]), arguments: args))
                }
                if obj["done"] as? Bool == true { break }
            }
            if !calls.isEmpty { cont.yield(.toolCalls(calls)) }
        }
    }
}

// ------------------------------------------------------------------ Anthropic (native API)

final class AnthropicProvider: LLMProvider {
    let apiKey: String
    let model: String
    let vision: Bool
    let handlesToolsInternally = false

    init(apiKey: String, model: String, vision: Bool) {
        self.apiKey = apiKey
        self.model = model
        self.vision = vision
    }

    /// Split system text out; convert the rest to Anthropic content blocks.
    private func convert(_ messages: [LLMMessage]) -> (system: String, msgs: [[String: Any]]) {
        var system = ""
        var out: [[String: Any]] = []
        for m in messages {
            if m.role == "system" {
                system += (system.isEmpty ? "" : "\n\n") + m.content
                continue
            }
            if m.role == "tool" {
                let block: [String: Any] = ["type": "tool_result", "tool_use_id": m.toolCallId, "content": m.content]
                // All tool_results for one assistant turn must share ONE user message.
                if var last = out.last, jstr(last["role"]) == "user",
                   var blocks = last["content"] as? [[String: Any]],
                   jstr(blocks.first?["type"]) == "tool_result" {
                    blocks.append(block)
                    last["content"] = blocks
                    out[out.count - 1] = last
                } else {
                    out.append(["role": "user", "content": [block]])
                }
                continue
            }
            var content: [[String: Any]] = []
            for b64 in m.images {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]])
            }
            if !m.content.isEmpty { content.append(["type": "text", "text": m.content]) }
            if m.role == "assistant" {
                for c in m.toolCalls {
                    content.append(["type": "tool_use", "id": c.id, "name": c.name, "input": c.arguments])
                }
            }
            if content.isEmpty { continue }
            out.append(["role": m.role, "content": content])
        }
        while let first = out.first, jstr(first["role"]) != "user" { out.removeFirst() }
        return (system, out)
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        makeStream { cont in
            let (system, msgs) = self.convert(messages)
            var body: [String: Any] = ["model": self.model, "max_tokens": 4096, "messages": msgs, "stream": true]
            if !system.isEmpty { body["system"] = system }
            if !tools.isEmpty {
                body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters] }
            }
            let req = try postJSON(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                body: body,
                headers: ["x-api-key": self.apiKey, "anthropic-version": "2023-06-01"]
            )
            let bytes = try await openBytes(req, providerName: "Claude")

            var pending: [Int: (id: String, name: String, json: String)] = [:]
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let obj = parseJSONLine(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                switch jstr(obj["type"]) {
                case "content_block_start":
                    let block = jdict(obj["content_block"])
                    if jstr(block["type"]) == "tool_use", let idx = obj["index"] as? Int {
                        pending[idx] = (id: jstr(block["id"]), name: jstr(block["name"]), json: "")
                    }
                case "content_block_delta":
                    let delta = jdict(obj["delta"])
                    switch jstr(delta["type"]) {
                    case "text_delta":
                        let t = jstr(delta["text"])
                        if !t.isEmpty { cont.yield(.text(t)) }
                    case "input_json_delta":
                        if let idx = obj["index"] as? Int, var e = pending[idx] {
                            e.json += jstr(delta["partial_json"])
                            pending[idx] = e
                        }
                    default: break
                    }
                case "error":
                    throw BuddyError("Claude: \(jstr(jdict(obj["error"])["message"]))")
                case "message_stop":
                    break
                default: break
                }
            }
            if !pending.isEmpty {
                let calls = pending.keys.sorted().map { idx -> ToolCallReq in
                    let e = pending[idx]!
                    let args = (e.json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
                    return ToolCallReq(id: e.id.isEmpty ? newCallId() : e.id, name: e.name, arguments: args)
                }
                cont.yield(.toolCalls(calls))
            }
        }
    }
}

// ------------------------------------------------------------------ factory (llm.py build_provider port)

func buildProvider(settings: BuddySettings, setQuiet: @escaping @Sendable (Double) -> Void) throws -> LLMProvider {
    switch settings.mode {
    case "apple":
        return try AppleBrainFactory.make(setQuiet: setQuiet)
    case "gemini":
        guard !settings.geminiKey.isEmpty else {
            throw BuddyError("No API key configured for Gemini. Add it in settings (gear icon).")
        }
        return OpenAICompatProvider(
            name: "gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            apiKey: settings.geminiKey, model: settings.geminiModel, vision: true
        )
    case "openai":
        guard !settings.openaiKey.isEmpty else {
            throw BuddyError("No API key configured for OpenAI. Add it in settings (gear icon).")
        }
        return OpenAICompatProvider(
            name: "openai",
            baseURL: "https://api.openai.com/v1",
            apiKey: settings.openaiKey, model: settings.openaiModel, vision: true
        )
    case "anthropic":
        guard !settings.anthropicKey.isEmpty else {
            throw BuddyError("No API key configured for Claude. Add it in settings (gear icon).")
        }
        return AnthropicProvider(apiKey: settings.anthropicKey, model: settings.anthropicModel, vision: true)
    case "ollama":
        return OllamaNativeProvider(
            baseURL: settings.ollamaBase, model: settings.ollamaModel,
            vision: settings.ollamaVision, think: settings.ollamaThink, keepAlive: settings.ollamaKeepAlive
        )
    case "gguf":
        let file = settings.ggufModel
        let path = Paths.models.appendingPathComponent(file)
        guard !file.isEmpty, FileManager.default.fileExists(atPath: path.path) else {
            throw BuddyError("No local model selected — download one in settings → Brain → Manage local models.")
        }
        let fallback = settings.ggufBackgroundModel.isEmpty
            ? nil
            : Paths.models.appendingPathComponent(settings.ggufBackgroundModel).path
        return try LlamaBrainFactory.make(
            modelPath: path.path, fallbackPath: fallback,
            contextLength: settings.ggufContext, displayName: file
        )
    default:
        throw BuddyError("Unknown brain mode: \(settings.mode)")
    }
}

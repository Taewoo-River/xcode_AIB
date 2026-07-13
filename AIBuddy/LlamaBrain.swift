import Foundation

// The "Local GGUF" brain: runs downloaded models (Gemma 4 E2B, Qwen3.5, …)
// fully on the iPad via llama.cpp (official xcframework, Metal GPU).

enum LlamaBrainFactory {
    static func make(modelPath: String, contextLength: Int, displayName: String) throws -> LLMProvider {
        #if canImport(llama)
        return LlamaLocalProvider(modelPath: modelPath, contextLength: contextLength, displayName: displayName)
        #else
        throw BuddyError("The local GGUF engine isn't included in this build — pick another brain in settings.")
        #endif
    }

    static var isAvailable: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }
}

#if canImport(llama)
import llama

// Chat-template control markers that must never reach the user. They leak in
// two ways: the model emitting control tokens mid-stream, and old contaminated
// history echoing them back — both are scrubbed.
let chatMarkers = [
    "<|im_end|>", "<|im_start|>", "<|endoftext|>", "<|eot_id|>", "<|end|>",
    "<end_of_turn>", "<start_of_turn>", "<eos>", "<bos>",
    "<|assistant|>", "<|user|>", "<|system|>"
]

func scrubMarkers(_ s: String) -> String {
    var t = s
    for m in chatMarkers { t = t.replacingOccurrences(of: m, with: "") }
    return t
}

// ------------------------------------------------------------------ cancel flag

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// ------------------------------------------------------------------ provider

final class LlamaLocalProvider: LLMProvider {
    let vision = false
    let handlesToolsInternally = false
    let modelPath: String
    let contextLength: Int
    let displayName: String

    init(modelPath: String, contextLength: Int, displayName: String) {
        self.modelPath = modelPath
        self.contextLength = contextLength
        self.displayName = displayName
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { cont in
            let flag = CancelFlag()
            cont.onTermination = { _ in flag.cancel() }
            // Filter out <think>…</think> reasoning so the user never sees/hears it.
            let filter = ThinkFilter()
            LlamaRuntime.shared.run(
                modelPath: modelPath,
                contextLength: Int32(contextLength),
                messages: messages,
                tools: tools,
                onDelta: { delta in
                    let visible = filter.feed(delta)
                    if !visible.isEmpty { cont.yield(.text(visible)) }
                    // a turn-boundary marker appeared as plain text: the model
                    // ended its turn (or started inventing the user's) — stop
                    if filter.sawTurnBoundary { flag.cancel() }
                },
                cancelled: { flag.isCancelled },
                completion: { error in
                    let rest = filter.flush()
                    if !rest.isEmpty { cont.yield(.text(rest)) }
                    if let error { cont.finish(throwing: error) } else { cont.finish() }
                }
            )
        }
    }
}

/// Strips <think>…</think> blocks from a streamed sequence of text deltas and
/// hard-stops at any chat-template turn boundary that leaks through as text
/// (e.g. the model writing "<|im_start|>user …" and role-playing the user).
/// A withheld tail guarantees a marker split across two deltas can never leak
/// a fragment like a lone "|".
final class ThinkFilter: @unchecked Sendable {
    private var buf = ""
    private var inThink = false
    private var stopped = false
    private let lock = NSLock()

    private static let thinkOpen = "<think>"
    private static let thinkClose = "</think>"
    private static let allTags = chatMarkers + [thinkOpen, thinkClose]
    private static let maxTag = allTags.map(\.count).max() ?? 0

    var sawTurnBoundary: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func feed(_ delta: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if stopped { return "" }
        buf += delta
        var out = ""
        while true {
            if inThink {
                if let r = buf.range(of: Self.thinkClose) {
                    buf = String(buf[r.upperBound...])
                    inThink = false
                    continue
                }
                // discard think content, but keep a tail that may be a partial "</think>"
                buf = String(buf.suffix(Self.heldTail(buf, tags: [Self.thinkClose])))
                return scrubMarkers(out)
            }
            // A complete turn-boundary marker → truncate here and stop for good.
            if let cut = Self.firstIndex(of: chatMarkers, in: buf) {
                out += buf[..<cut]
                stopped = true
                buf = ""
                return scrubMarkers(out)
            }
            // A complete <think> → emit what precedes it, then enter think mode.
            if let r = buf.range(of: Self.thinkOpen) {
                out += buf[..<r.lowerBound]
                buf = String(buf[r.upperBound...])
                inThink = true
                continue
            }
            // Nothing complete: emit all but a tail that could begin any tag.
            let hold = Self.heldTail(buf, tags: Self.allTags)
            let cut = buf.index(buf.endIndex, offsetBy: -hold)
            out += buf[..<cut]
            buf = String(buf[cut...])
            return scrubMarkers(out)
        }
    }

    func flush() -> String {
        lock.lock(); defer { lock.unlock() }
        if stopped || inThink { buf = ""; return "" }
        var rest = buf
        buf = ""
        // Truncate at any complete marker…
        if let cut = Self.firstIndex(of: chatMarkers, in: rest) {
            rest = String(rest[..<cut])
        }
        // …and drop a trailing fragment that is the start of a marker
        // (a cut-off "<|im_end|>" left as "<|im_end|", or a lone "|").
        let tail = Self.heldTail(rest, tags: Self.allTags)
        if tail > 0 {
            rest = String(rest.dropLast(tail))
        }
        return scrubMarkers(rest)
    }

    /// Earliest index at which any of `tags` completely occurs in `s`.
    private static func firstIndex(of tags: [String], in s: String) -> String.Index? {
        var earliest: String.Index? = nil
        for t in tags {
            if let r = s.range(of: t), earliest == nil || r.lowerBound < earliest! {
                earliest = r.lowerBound
            }
        }
        return earliest
    }

    /// Length of the trailing run of `s` that is a prefix of some tag — the
    /// chars we must withhold because they might complete a tag next delta.
    private static func heldTail(_ s: String, tags: [String]) -> Int {
        let window = min(maxTag - 1, s.count)
        if window <= 0 { return 0 }
        for k in stride(from: window, through: 1, by: -1) {
            let tail = String(s.suffix(k))
            if tags.contains(where: { $0.hasPrefix(tail) }) { return k }
        }
        return 0
    }
}

// ------------------------------------------------------------------ runtime
// One shared runtime: serializes llama.cpp access and keeps the last model
// (and its KV cache) warm so follow-up replies skip prompt re-processing.

final class LlamaRuntime: @unchecked Sendable {
    static let shared = LlamaRuntime()

    private let queue = DispatchQueue(label: "aibuddy.llama", qos: .userInitiated)
    private var backendReady = false
    private var loadedPath = ""
    private var model: OpaquePointer? = nil
    private var ctx: OpaquePointer? = nil
    private var vocab: OpaquePointer? = nil
    private var nCtx: Int32 = 0
    private var kvTokens: [llama_token] = []

    func run(
        modelPath: String,
        contextLength: Int32,
        messages: [LLMMessage],
        tools: [ToolSpec],
        onDelta: @escaping @Sendable (String) -> Void,
        cancelled: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async {
            do {
                try self.ensureLoaded(path: modelPath, contextLength: contextLength)
                let prompt = self.renderPrompt(messages: messages, tools: tools)
                try self.generate(prompt: prompt, onDelta: onDelta, cancelled: cancelled)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Called when the user switches models to release ~GBs of memory.
    func unloadAsync() {
        queue.async { self.unload() }
    }

    // ------------------------------------------------------------- load / unload

    private func ensureLoaded(path: String, contextLength: Int32) throws {
        if !backendReady {
            llama_backend_init()
            backendReady = true
        }
        if loadedPath == path, ctx != nil, nCtx >= contextLength { return }
        unload()

        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99       // run everything on the Metal GPU
        mp.use_mmap = true         // file-backed weights keep memory pressure down
        guard let m = llama_model_load_from_file(path, mp) else {
            throw BuddyError("Couldn't load the model — the download may be incomplete/corrupt, or the architecture is unsupported. Try re-downloading it in settings.")
        }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextLength)
        cp.n_batch = 512
        cp.n_ubatch = 512
        let threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw BuddyError("Couldn't start the model (out of memory?) — try a smaller context length or a smaller model.")
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        nCtx = Int32(llama_n_ctx(c))
        loadedPath = path
        kvTokens = []
    }

    private func unload() {
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil; model = nil; vocab = nil
        loadedPath = ""
        kvTokens = []
    }

    // ------------------------------------------------------------- prompt building

    private func renderPrompt(messages: [LLMMessage], tools: [ToolSpec]) -> String {
        var list: [(role: String, content: String)] = []
        for m in messages {
            switch m.role {
            case "system":
                var content = m.content
                if !tools.isEmpty {
                    // Kept deliberately terse: verbose protocol text gets parroted
                    // back verbatim by small models.
                    content += "\n\nYou can call tools for live info. To call one, output a single line of JSON and stop:\n"
                    content += "{\"name\": \"web_search\", \"parameters\": {\"query\": \"...\"}}\n"
                    for t in tools { content += "- \(t.name): \(t.description)\n" }
                    content += "After a tool runs you receive its output; then answer the user in plain words with no JSON."
                }
                list.append(("system", content))
            case "tool":
                // Result framed as a plain observation the model won't echo.
                list.append(("user", "(\(m.toolName) returned) \(scrubMarkers(m.content))"))
            default:
                // scrub: old replies may carry leaked chat markers — echoing
                // them back teaches the model to emit even more of them
                var content = scrubMarkers(m.content)
                if !m.images.isEmpty {
                    content += "\n(An image was attached, but this local model can't see images — say so if it matters.)"
                }
                if !content.isEmpty { list.append((m.role, content)) }
            }
        }

        if let m = model, let tmpl = llama_model_chat_template(m, nil) {
            if let rendered = applyTemplate(tmpl, list: list) { return rendered }
        }
        // ChatML fallback — understood by most instruct models
        var out = ""
        for m in list { out += "<|im_start|>\(m.role)\n\(m.content)<|im_end|>\n" }
        out += "<|im_start|>assistant\n"
        return out
    }

    private func applyTemplate(_ tmpl: UnsafePointer<CChar>, list: [(role: String, content: String)]) -> String? {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { for p in cStrings { free(p) } }
        var cMsgs: [llama_chat_message] = []
        var totalChars = 0
        for m in list {
            guard let r = strdup(m.role), let c = strdup(m.content) else { return nil }
            cStrings.append(r)
            cStrings.append(c)
            cMsgs.append(llama_chat_message(role: UnsafePointer(r), content: UnsafePointer(c)))
            totalChars += m.content.utf8.count + 32
        }
        var cap = Int32(totalChars * 2 + 2048)
        var buf = [CChar](repeating: 0, count: Int(cap))
        var n = llama_chat_apply_template(tmpl, &cMsgs, cMsgs.count, true, &buf, cap)
        if n > cap {
            cap = n + 64
            buf = [CChar](repeating: 0, count: Int(cap))
            n = llama_chat_apply_template(tmpl, &cMsgs, cMsgs.count, true, &buf, cap)
        }
        guard n > 0, n < cap else { return nil }
        return String(cString: buf)
    }

    // ------------------------------------------------------------- generation

    private func tokenize(_ text: String) -> [llama_token] {
        let maxTokens = text.utf8.count + 64
        var tokens = [llama_token](repeating: 0, count: maxTokens)
        let n = text.withCString { cs in
            llama_tokenize(vocab, cs, Int32(text.utf8.count), &tokens, Int32(maxTokens), true, true)
        }
        guard n > 0 else { return [] }
        return Array(tokens[0..<Int(n)])
    }

    private func piece(_ token: llama_token, renderSpecial: Bool) -> Data {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(vocab, token, &buf, 256, 0, renderSpecial)
        guard n > 0 else { return Data() }
        return buf[0..<Int(n)].withUnsafeBufferPointer { bp in
            Data(bytes: bp.baseAddress!, count: Int(n))
        }
    }

    private func decode(_ tokens: inout [llama_token], from start: Int, count: Int) -> Bool {
        var ok = true
        tokens.withUnsafeMutableBufferPointer { bp in
            let batch = llama_batch_get_one(bp.baseAddress! + start, Int32(count))
            ok = llama_decode(self.ctx, batch) == 0
        }
        return ok
    }

    private func generate(
        prompt: String,
        onDelta: @escaping (String) -> Void,
        cancelled: @escaping () -> Bool
    ) throws {
        var tokens = tokenize(prompt)
        guard !tokens.isEmpty else { throw BuddyError("Tokenizing the prompt failed.") }
        guard tokens.count < Int(nCtx) - 32 else {
            throw BuddyError("The conversation is too long for the model's context window (\(nCtx) tokens) — clear the chat or raise the context length in settings.")
        }

        // iOS blocks the GPU while backgrounded — a Metal decode would fail and
        // wedge the context. Refuse cleanly BEFORE touching the model so nothing
        // is corrupted; the reply just waits for foreground (or a cloud brain).
        if AppState.shared.isBackground {
            throw BuddyError("I can't run the on-device model while the app is in the background — Apple blocks GPU use there. Bring AI Buddy to the front, or switch to a cloud brain (Gemini/OpenAI/Claude) which works anywhere, even with the screen off.")
        }

        // Reuse the KV cache for the shared prefix with the previous turn.
        var common = 0
        while common < tokens.count - 1, common < kvTokens.count, kvTokens[common] == tokens[common] {
            common += 1
        }
        guard let mem = llama_get_memory(ctx) else { throw BuddyError("Model context lost — try again.") }
        if common == 0 {
            llama_memory_clear(mem, true)
        } else {
            _ = llama_memory_seq_rm(mem, 0, Int32(common), -1)
        }
        kvTokens = Array(tokens[0..<common])

        // Process the (new part of the) prompt in batches.
        var idx = common
        while idx < tokens.count {
            if cancelled() { return }
            if AppState.shared.isBackground { throw backgroundError() }
            let n = min(512, tokens.count - idx)
            guard decode(&tokens, from: idx, count: n) else {
                // A failed decode leaves the Metal context wedged — fully unload
                // so the next attempt reloads cleanly (no app restart needed).
                unload()
                throw BuddyError("The model hit an error (decode failed) — I've reset it, so just ask again.")
            }
            kvTokens.append(contentsOf: tokens[idx..<idx + n])
            idx += n
        }

        // Sampler chain: top-k → top-p → min-p → temperature → dist
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(chain) }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1..<UInt32.max)))

        var pending = Data()
        var produced = 0
        let maxNew = Int(nCtx) - tokens.count - 16
        while produced < maxNew {
            if cancelled() { break }
            // Went to background mid-reply: stop cleanly, keeping the text so far,
            // rather than issuing a Metal decode that iOS would kill.
            if AppState.shared.isBackground { break }
            let tok = llama_sampler_sample(chain, ctx, -1)   // samples + accepts
            if llama_vocab_is_eog(vocab, tok) { break }

            // Render WITHOUT special tokens: control tokens (<|im_start|>,
            // <|im_end|>, role tags, …) come back empty and never reach the
            // user. Their special rendering is only inspected to detect
            // think-blocks and missed end-of-turn markers.
            let visible = piece(tok, renderSpecial: false)
            if visible.isEmpty {
                let control = String(decoding: piece(tok, renderSpecial: true), as: UTF8.self)
                if control.contains("<think>") {
                    // let the textual ThinkFilter downstream handle the block
                    pending.append(Data("<think>".utf8))
                } else if control.contains("</think>") {
                    pending.append(Data("</think>".utf8))
                } else if chatMarkers.contains(where: { control.contains($0) }) {
                    break   // an end-of-turn the vocab didn't flag as EOG
                }
                // any other control token: swallow silently
            } else {
                pending.append(visible)
            }
            // emit only complete UTF-8 (multi-byte chars can split across tokens)
            if let s = String(data: pending, encoding: .utf8) {
                if !s.isEmpty { onDelta(s) }
                pending.removeAll(keepingCapacity: true)
            } else if pending.count > 16 {
                onDelta(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
            }
            var single: [llama_token] = [tok]
            guard decode(&single, from: 0, count: 1) else {
                unload()   // self-heal a wedged context
                break
            }
            kvTokens.append(tok)
            produced += 1
        }
        if !pending.isEmpty {
            onDelta(String(decoding: pending, as: UTF8.self))
        }
    }

    private func backgroundError() -> BuddyError {
        BuddyError("I can't run the on-device model while the app is in the background — Apple blocks GPU use there. Bring AI Buddy to the front, or switch to a cloud brain (Gemini/OpenAI/Claude).")
    }
}
#endif

import Foundation

// The "Local" brain: Apple's on-device foundation model (Apple Intelligence),
// exposed to apps on iPadOS 26+ via the FoundationModels framework.
// Free, private, works offline — and your iPad Air M3 supports it.
//
// Everything is wrapped in #if canImport so the app still builds and runs
// (with cloud brains) on a Swift Playgrounds version that lacks the SDK.

enum AppleBrainFactory {
    static func make(setQuiet: @escaping @Sendable (Double) -> Void) throws -> LLMProvider {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let problem = AppleOnDeviceProvider.availabilityProblem() {
                throw BuddyError(problem)
            }
            return AppleOnDeviceProvider(setQuiet: setQuiet)
        }
        throw BuddyError("The on-device brain needs iPadOS 26 or newer — update iPadOS, or pick a cloud brain in settings.")
        #else
        throw BuddyError("This build was compiled without the FoundationModels SDK — rebuild with the latest workflow (it now selects the newest Xcode on the runner), or pick another brain in settings.")
        #endif
    }

    /// One-line status for the settings screen.
    static func statusLine() -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return AppleOnDeviceProvider.availabilityProblem() ?? "Ready — Apple Intelligence on-device model is available."
        }
        return "Needs iPadOS 26 or newer."
        #else
        return "Not available — this build was compiled without the FoundationModels SDK (rebuild with the latest workflow)."
        #endif
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
final class AppleOnDeviceProvider: LLMProvider {
    let vision = false
    let handlesToolsInternally = true   // FoundationModels runs tools itself
    let setQuiet: @Sendable (Double) -> Void

    init(setQuiet: @escaping @Sendable (Double) -> Void) {
        self.setQuiet = setQuiet
    }

    static func availabilityProblem() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device can't run Apple Intelligence — pick a cloud brain in settings."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri, then try again."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading — try again in a few minutes."
        case .unavailable(_):
            return "The on-device model is unavailable right now — pick a cloud brain in settings."
        }
    }

    // ------------------------------------------------------------- tools

    struct WebSearchTool: Tool {
        let name = "web_search"
        let description = "Search the internet. Use for anything current, factual, or outside your certain knowledge: news, weather, prices, releases, people, places."

        @Generable
        struct Arguments {
            @Guide(description: "The search query.")
            var query: String
        }

        func call(arguments: Arguments) async throws -> String {
            await Toolbox.webSearch(query: arguments.query)
        }
    }

    struct ReadWebpageTool: Tool {
        let name = "read_webpage"
        let description = "Fetch a URL and return its readable text content. Use after web_search to read a promising result in full."

        @Generable
        struct Arguments {
            @Guide(description: "Full http(s) URL to read.")
            var url: String
        }

        func call(arguments: Arguments) async throws -> String {
            await Toolbox.readWebpage(urlString: arguments.url)
        }
    }

    struct LookAtScreenTool: Tool {
        let name = "look_at_screen"
        let description = "Check the user's most recent screenshot. Note: this brain cannot view images, so the result is only a status report."

        @Generable
        struct Arguments {}

        func call(arguments: Arguments) async throws -> String {
            switch await ScreenPeek.latestScreenshot() {
            case .noPermission:
                return "No Photos permission — the user must allow it in iPad Settings → Privacy & Security → Photos → AI Buddy."
            case .notFound:
                return "No screenshot found — ask the user to take one (Top button + Volume Up), and note that this on-device brain can't see images anyway; suggest switching to Gemini/OpenAI/Claude for that."
            case .stale(let minutes):
                return "Latest screenshot is \(minutes) minutes old. Also: this on-device brain can't view images — suggest a cloud brain (Gemini/OpenAI/Claude) for screen-looking."
            case .found(_, let age):
                return "A screenshot from \(ScreenPeek.ageText(seconds: age)) ago exists, but this on-device brain can't view images. Tell the user to switch to a cloud brain (Gemini/OpenAI/Claude) in settings to actually see it."
            }
        }
    }

    struct SetQuietTool: Tool {
        let name = "set_quiet"
        let description = "Silence your own proactive conversation-starting. Call when the user asks you to be quiet or to leave them alone. minutes=0 turns proactive chatter back on."
        let setQuiet: @Sendable (Double) -> Void

        @Generable
        struct Arguments {
            @Guide(description: "How long to stay quiet, in minutes. 0 to re-enable.")
            var minutes: Double
        }

        func call(arguments: Arguments) async throws -> String {
            setQuiet(arguments.minutes)
            return arguments.minutes > 0
                ? "Done — you won't start conversations for \(Int(arguments.minutes)) minutes."
                : "Done — proactive conversations re-enabled."
        }
    }

    // ------------------------------------------------------------- streaming

    func stream(messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    try await self.run(messages: messages, continuation: cont)
                    cont.finish()
                } catch {
                    cont.finish(throwing: BuddyError(Self.describe(error)))
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func run(messages: [LLMMessage], continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        var instructions = messages.first(where: { $0.role == "system" })?.content ?? ""
        instructions += "\n\nYou will be shown the conversation so far. Continue it: reply to the last user message with only your own message text — no speaker labels."

        let session = LanguageModelSession(
            tools: [WebSearchTool(), ReadWebpageTool(), LookAtScreenTool(), SetQuietTool(setQuiet: setQuiet)],
            instructions: instructions
        )

        // The on-device model has a small context window (~4k tokens);
        // retry once with a shorter transcript if we blow past it.
        var attempt = Array(messages.filter { $0.role != "system" })
        for round in 0..<2 {
            do {
                let prompt = Self.transcript(attempt)
                var seen = ""
                let stream = session.streamResponse(to: prompt)
                for try await partial in stream {
                    let full: String = partial.content
                    if full.hasPrefix(seen) {
                        let delta = String(full.dropFirst(seen.count))
                        if !delta.isEmpty { continuation.yield(.text(delta)) }
                    } else {
                        continuation.yield(.text(full))
                    }
                    seen = full
                }
                return
            } catch {
                if round == 0 && attempt.count > 4 {
                    attempt = Array(attempt.suffix(4))  // context overflow → try shorter
                    continue
                }
                throw error
            }
        }
    }

    private static func transcript(_ messages: [LLMMessage]) -> String {
        var out = ""
        for m in messages {
            let who = m.role == "user" ? "User" : "You"
            out += "\(who): \(m.content)\n"
            if !m.images.isEmpty {
                out += "(The user attached an image, but you cannot view images on this brain — say so if it matters.)\n"
            }
        }
        return out
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize:
                return "That conversation got too long for the on-device model — clear the chat in settings, or switch to a cloud brain."
            case .guardrailViolation:
                return "The on-device model declined to answer that one (Apple safety guardrails)."
            default:
                return "On-device model error: \(e.localizedDescription)"
            }
        }
        return "On-device model error: \(error.localizedDescription)"
    }
}
#endif

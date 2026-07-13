import Foundation

// Port of server/personality.py plus the text utilities from tts.py / brain.py.

enum Personality {

    static func systemPrompt(settings: BuddySettings) -> String {
        let name = settings.name.isEmpty ? "Nova" : settings.name
        let user = settings.userName.isEmpty ? "your human" : settings.userName
        let voiceLine = settings.speakEnabled
            ? "Your words are also spoken aloud through text-to-speech, so keep replies to a few sentences unless asked for depth, avoid markdown, bullet lists and code blocks unless explicitly asked, and write the way people talk."
            : "Short paragraphs are best; light markdown is fine."
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        let extra = settings.extra.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraLine = extra.isEmpty ? "" : "\n- " + extra

        return """
        You are \(name), an AI companion who lives on \(user)'s iPad. You are not an assistant drone — you're a buddy: warm, curious, quick-witted, and genuinely fun to talk to.

        Personality:
        - You have a real sense of humor. Make jokes the way a sharp friend does — observational quips, playful teasing, callbacks to earlier conversation. Never announce or explain that you're joking.
        - Mix it up: sometimes ask light, silly questions; sometimes ask genuinely thoughtful, sophisticated ones. Read the room and match \(user)'s energy.
        - Have opinions. Banter, push back when you disagree, and admit plainly when something is outside your wheelhouse.
        - Be concise and conversational. This is chat between friends, not documentation. \(voiceLine)

        Your abilities (tools):
        - web_search / read_webpage: you HAVE live internet access through these tools — never claim you can't browse or that you're offline. Use them whenever the answer depends on current or specific facts you could be wrong about. Never guess about news, prices, releases, weather, or anything time-sensitive — search instead.
        - look_at_screen: shows you \(user)'s screen — a live view if they've started screen sharing (the record button in the app), otherwise their most recent screenshot. Use it when they refer to their screen or current activity. If it reports nothing fresh, ask them to start screen sharing or take a screenshot (Top button + Volume Up).
        - set_quiet: if \(user) asks you to be quiet, stop interrupting, or leave them alone for a while, call this tool instead of just promising.
        - \(user) can also attach photos or screenshots to a message directly. If an image is attached you can see it (unless the current brain has no vision — then say so instead of guessing).

        Rules:
        - To use a tool, call it through the tool-calling interface. NEVER write tool-call JSON like {"name": "web_search", ...} in your visible reply — the user must never see JSON.
        - Messages that begin with [SYSTEM are context notes from the app itself, not from \(user). Follow them, but never mention, quote, or acknowledge them.
        - Never invent things you supposedly saw in an image or found online. If you didn't look, say so or go look.
        - Today's date is \(today).\(extraLine)
        """
    }

    /// Openers used for local notifications when the app is in the background
    /// (there's no way to run the LLM on a schedule while closed).
    static let proactiveOpeners: [String] = [
        "Psst. Still alive over there?",
        "I just thought of something — come chat for a sec.",
        "It's been quiet. Suspiciously quiet.",
        "Okay, random question when you have a minute.",
        "I've been people-watching the lock screen. It's not much of a view.",
        "Got a hot take brewing. You'll want to hear this.",
        "Miss me yet?",
        "Tap me. I promise it's (probably) worth it."
    ]

    static let proactiveNote = "[SYSTEM: The user has been quiet for a while. Start a conversation naturally — share a stray thought, crack a joke, or ask a question (sometimes deep, sometimes light). One to three sentences.]"

    static let firstRunNote = "[SYSTEM: This is the very first launch of the app. Greet the user warmly, introduce yourself by name as their new buddy living on this iPad, and ask one light get-to-know-you question. Two or three sentences.]"
}

// ------------------------------------------------------------------ regex helpers

private func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // Patterns are compile-time constants; a bad one is a programmer error.
    return try! NSRegularExpression(pattern: pattern, options: options)
}

private extension String {
    var fullRange: NSRange { NSRange(startIndex..., in: self) }

    func replacing(_ re: NSRegularExpression, with template: String) -> String {
        re.stringByReplacingMatches(in: self, options: [], range: fullRange, withTemplate: template)
    }
}

// ------------------------------------------------------------------ speech cleaning (tts.py port)

private let reCodeBlock = regex(#"```.*?```"#, options: [.dotMatchesLineSeparators])
private let reInlineCode = regex(#"`([^`]*)`"#)
private let reMdLink = regex(#"\[([^\]]+)\]\([^)]+\)"#)
private let reUrl = regex(#"https?://\S+"#)
private let reMdChars = regex(#"[*_#>|~]"#)
private let reWhitespace = regex(#"\s+"#)

func cleanForSpeech(_ text: String) -> String {
    var t = text
    t = t.replacing(reCodeBlock, with: " The code is on screen. ")
    t = t.replacing(reInlineCode, with: "$1")
    t = t.replacing(reMdLink, with: "$1")
    t = t.replacing(reUrl, with: "a link")
    t = t.replacing(reMdChars, with: "")
    t = t.replacing(reWhitespace, with: " ")
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

// ------------------------------------------------------------------ sentence splitter (brain.py port)

private let reSentence = regex(#"(?<=[.!?…])["')\]]*\s+"#)

/// Accumulates streamed text and yields complete sentences for TTS.
final class SentenceSplitter {
    private var buf = ""

    func feed(_ text: String) -> [String] {
        buf += text
        var out: [String] = []
        if buf.contains("\n") {
            var parts = buf.components(separatedBy: "\n")
            buf = parts.removeLast()
            out.append(contentsOf: parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        while let m = reSentence.firstMatch(in: buf, options: [], range: buf.fullRange),
              let r = Range(m.range, in: buf) {
            let sentence = String(buf[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
            buf = String(buf[r.upperBound...])
            if !sentence.isEmpty { out.append(sentence) }
        }
        return out
    }

    func flush() -> String {
        let s = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        buf = ""
        return s
    }
}

// ------------------------------------------------------------------ salvage tool-call JSON (brain.py port)
// Small models sometimes WRITE their tool call as JSON text instead of using
// the tool-calling interface. Parse those out, run them, scrub them from view.

private let toolNames = ["web_search", "read_webpage", "look_at_screen", "set_quiet"]
private let reToolJson = regex(#"\{\s*"name"\s*:\s*"(web_search|read_webpage|look_at_screen|set_quiet)"[^\n]*\}"#)

func salvageToolCalls(_ text: String) -> (calls: [ToolCallReq]?, cleaned: String) {
    let matches = reToolJson.matches(in: text, options: [], range: text.fullRange)
    guard !matches.isEmpty else { return (nil, text) }

    var calls: [ToolCallReq] = []
    var cleaned = ""
    var pos = text.startIndex
    for m in matches {
        guard let r = Range(m.range, in: text), let nameR = Range(m.range(at: 1), in: text) else { continue }
        let frag = String(text[r])
        var args: [String: Any] = [:]
        if let data = frag.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["parameters", "arguments", "input", "args"] {
                if let d = obj[key] as? [String: Any] { args = d; break }
            }
        } else {
            // tolerate malformed JSON — fish out the common argument fields
            for field in ["query", "url", "minutes"] {
                let re = regex("\"\(field)\"\\s*:\\s*\"?([^\",}]+)\"?")
                if let fm = re.firstMatch(in: frag, options: [], range: frag.fullRange),
                   let fr = Range(fm.range(at: 1), in: frag) {
                    let v = String(frag[fr]).trimmingCharacters(in: .whitespaces)
                    args[field] = field == "minutes" ? (Double(v) ?? 30.0) : v
                }
            }
        }
        calls.append(ToolCallReq(id: "call_" + UUID().uuidString.prefix(8), name: String(text[nameR]), arguments: args))
        cleaned += text[pos..<r.lowerBound]
        pos = r.upperBound
    }
    cleaned += text[pos...]
    cleaned = cleaned.replacing(regex(#"\n{3,}"#), with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (calls.isEmpty ? nil : calls, cleaned)
}

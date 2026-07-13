import Foundation
import SwiftUI
import UIKit
import UserNotifications

// Port of server/brain.py: conversation loop, tool rounds, interruption,
// proactivity, history persistence.

@MainActor
final class BuddyEngine: ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var currentReply = ""            // streaming assistant text
    @Published var isGenerating = false
    @Published var toolStatus: String? = nil    // "🔎 searching: …"
    @Published var errorText: String? = nil
    @Published var quietUntil: Date? = nil
    @Published var settings: BuddySettings {
        didSet {
            saveSettings()
            speaker.configure(settings: settings)
            voice.configure(settings: settings)
        }
    }

    let speaker = Speaker()
    let voice = VoiceInput()

    private var genTask: Task<Void, Never>? = nil
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var utt = 0                          // bumping invalidates in-flight replies
    private var lastActivity = Date()
    private var consecutiveProactive = 0
    private var isForeground = true
    private var proactiveTimer: Timer? = nil
    private let maxToolRounds = 6

    init() {
        settings = Self.loadSettings()
        messages = Self.loadHistory()
        try? FileManager.default.createDirectory(at: Paths.avatars, withIntermediateDirectories: true)
        ScreenWatch.shared.start()   // receives live frames while a broadcast runs
        speaker.configure(settings: settings)
        voice.configure(settings: settings)

        voice.onFinalUtterance = { [weak self] text in
            Task { @MainActor in self?.send(text: text) }
        }
        voice.onSpeechDetected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.speaker.isSpeaking || self.isGenerating { self.interrupt() }
            }
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        proactiveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maybeProactive() }
        }

        if messages.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard self.messages.isEmpty, !self.isGenerating else { return }
                self.messages.append(ChatMessage(role: "user", content: Personality.firstRunNote, hidden: true))
                self.respond()
            }
        }
    }

    // ------------------------------------------------------------- input

    func send(text: String, images: [String] = []) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !images.isEmpty else { return }
        consecutiveProactive = 0
        lastActivity = Date()
        interrupt()
        errorText = nil
        messages.append(ChatMessage(role: "user", content: t, images: images))
        saveHistory()
        respond()
    }

    /// Cancel any in-flight response; keep whatever text already arrived.
    func interrupt() {
        let partial = currentReply
        genTask?.cancel()
        genTask = nil
        utt += 1
        speaker.stopAll()
        currentReply = ""
        toolStatus = nil
        isGenerating = false
        if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(ChatMessage(role: "assistant", content: partial))
            saveHistory()
        }
    }

    func applyQuiet(minutes: Double) {
        quietUntil = minutes > 0 ? Date().addingTimeInterval(minutes * 60) : nil
    }

    func clearHistory() {
        interrupt()
        messages = []
        saveHistory()
    }

    // ------------------------------------------------------------- proactive

    func maybeProactive() {
        // in the background the app stays alive only while the mic is armed —
        // and then it can genuinely speak up, so allow it
        guard settings.proactiveEnabled, isForeground || voice.armed else { return }
        if let q = quietUntil, Date() < q { return }
        if isGenerating { return }
        if consecutiveProactive >= settings.maxConsecutive { return }
        if Date().timeIntervalSince(lastActivity) < settings.idleMinutes * 60 { return }
        guard (try? buildProvider(settings: settings, setQuiet: { _ in })) != nil else { return }

        consecutiveProactive += 1
        lastActivity = Date()
        // If the screen broadcast is running and the brain has vision, let the
        // buddy react to what the user is actually doing (like the PC version).
        if settings.screenEnabled, settings.visionCapable, let b64 = ScreenWatch.shared.freshFrameB64() {
            messages.append(ChatMessage(
                role: "user",
                content: "[SYSTEM: The user has been quiet for a while. You can see their screen right now (attached). Start a conversation naturally — react to what they seem to be doing, share a stray thought, crack a joke, or ask a question (sometimes deep, sometimes light). One to three sentences.]",
                hidden: true,
                images: [b64]
            ))
        } else {
            messages.append(ChatMessage(role: "user", content: Personality.proactiveNote, hidden: true))
        }
        saveHistory()
        respond()
    }

    /// While the app is closed we can't run the LLM, so schedule notification
    /// nudges with personality-flavored openers instead.
    func enteredBackground() {
        isForeground = false
        AppState.shared.isBackground = true   // blocks GGUF/Metal decode while backgrounded
        // Re-evaluate the audio session: in the background we keep the mic alive
        // (rather than pausing it for earbud output), so listening continues.
        AudioSessionManager.shared.ensureActive()
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        // with the mic armed the app keeps running and speaks for real —
        // notification nudges would just double up
        guard settings.proactiveEnabled, settings.notifyWhenClosed, !voice.armed else { return }
        if let q = quietUntil, Date() < q { return }
        var openers = Personality.proactiveOpeners.shuffled()
        for i in 0..<max(1, settings.maxConsecutive) {
            let content = UNMutableNotificationContent()
            content.title = settings.name
            content.body = openers.isEmpty ? "Hey." : openers.removeFirst()
            content.sound = .default
            let delay = max(60, settings.idleMinutes * 60 * Double(i + 1))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            center.add(UNNotificationRequest(identifier: "proactive-\(i)", content: content, trigger: trigger))
        }
    }

    func enteredForeground() {
        isForeground = true
        AppState.shared.isBackground = false
        lastActivity = Date()
        AudioSessionManager.shared.ensureActive()   // restore foreground routing
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // ------------------------------------------------------------- generation

    private func buildMessages(vision: Bool) -> [LLMMessage] {
        var recent = Array(messages.suffix(settings.historyLimit))
        while let f = recent.first, f.role != "user" { recent.removeFirst() }
        var out = [LLMMessage(role: "system", content: Personality.systemPrompt(settings: settings))]
        for (i, h) in recent.enumerated() {
            var m = LLMMessage(role: h.role, content: h.content)
            // Only the newest message keeps its images — old ones waste tokens.
            if !h.images.isEmpty && i == recent.count - 1 {
                if vision {
                    m.images = h.images
                } else {
                    m.content += "\n[SYSTEM: an image was attached, but the current brain can't see images — say so if it matters.]"
                }
            }
            out.append(m)
        }
        return out
    }

    private func respond() {
        let myUtt = utt
        isGenerating = true
        currentReply = ""
        beginBackgroundWork()   // let the reply finish if the user switches apps
        genTask = Task { [weak self] in
            await self?.respondInner(myUtt: myUtt)
            await MainActor.run { [weak self] in
                if self?.isGenerating == false { self?.endBackgroundWork() }
            }
        }
    }

    /// iOS grants ~30 s of background runtime per task; combined with the
    /// `audio` background mode (active while speaking or listening), the buddy
    /// keeps working when the app isn't frontmost.
    private func beginBackgroundWork() {
        endBackgroundWork()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "aibuddy.reply") { [weak self] in
            Task { @MainActor in self?.endBackgroundWork() }
        }
    }

    private func endBackgroundWork() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func respondInner(myUtt: Int) async {
        let splitter = SentenceSplitter()
        let speak = settings.speakEnabled
        var fullText = ""

        func emit(_ delta: String) {
            guard myUtt == utt else { return }
            fullText += delta
            currentReply = fullText
            if speak {
                for s in splitter.feed(delta) { speaker.enqueue(cleanForSpeech(s)) }
            }
        }

        do {
            let provider = try buildProvider(settings: settings) { [weak self] m in
                Task { @MainActor in self?.applyQuiet(minutes: m) }
            }
            var msgs = buildMessages(vision: provider.vision)
            let tools = provider.handlesToolsInternally ? [] : Toolbox.toolSpecs()

            for _ in 0..<maxToolRounds {
                var roundText = ""
                var calls: [ToolCallReq]? = nil
                for try await ev in provider.stream(messages: msgs, tools: tools) {
                    try Task.checkCancellation()
                    switch ev {
                    case .text(let t):
                        roundText += t
                        emit(t)
                    case .toolCalls(let c):
                        calls = c
                    }
                }
                try Task.checkCancellation()

                if calls == nil {
                    // The model may have written its tool call as JSON text — salvage it.
                    let (salvaged, cleaned) = salvageToolCalls(roundText)
                    if let salvaged {
                        fullText = String(fullText.dropLast(roundText.count)) + cleaned
                        roundText = cleaned
                        calls = salvaged
                        if myUtt == utt { currentReply = fullText }
                    }
                }
                guard let theCalls = calls, !theCalls.isEmpty else { break }

                msgs.append(LLMMessage(role: "assistant", content: roundText, toolCalls: theCalls))
                for call in theCalls {
                    try Task.checkCancellation()
                    if myUtt == utt { toolStatus = Self.statusLabel(call) }
                    let (result, extra) = await runTool(call, vision: provider.vision)
                    msgs.append(LLMMessage(role: "tool", content: result, toolCallId: call.id, toolName: call.name))
                    if let extra { msgs.append(extra) }
                }
                if myUtt == utt { toolStatus = nil }
            }

            // Thinking models occasionally spend the whole turn on internal
            // reasoning and emit no visible text — nudge once for a plain reply.
            if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                msgs.append(LLMMessage(role: "user", content: "[SYSTEM: Your reply came out empty. Answer the user now in plain text.]"))
                for try await ev in provider.stream(messages: msgs, tools: []) {
                    try Task.checkCancellation()
                    if case .text(let t) = ev { emit(t) }
                }
            }

            let rest = splitter.flush()
            if speak && !rest.isEmpty && myUtt == utt { speaker.enqueue(cleanForSpeech(rest)) }

            guard myUtt == utt else { return }
            if !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(ChatMessage(role: "assistant", content: fullText))
                saveHistory()
            }
            lastActivity = Date()
            currentReply = ""
            toolStatus = nil
            isGenerating = false
            genTask = nil
        } catch is CancellationError {
            // interrupt() already preserved the partial reply and reset state
        } catch {
            guard myUtt == utt else { return }
            if !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(ChatMessage(role: "assistant", content: fullText))
                saveHistory()
            }
            errorText = error.localizedDescription
            currentReply = ""
            toolStatus = nil
            isGenerating = false
            genTask = nil
        }
    }

    private static func statusLabel(_ call: ToolCallReq) -> String {
        switch call.name {
        case "web_search": return "🔎 searching: \(jstr(call.arguments["query"]))"
        case "read_webpage": return "📄 reading a page…"
        case "set_quiet": return "🤫 okay, going quiet"
        case "look_at_screen": return "👀 peeking at your latest screenshot…"
        default: return "⚙️ \(call.name)…"
        }
    }

    // ------------------------------------------------------------- tools

    private func runTool(_ call: ToolCallReq, vision: Bool) async -> (String, LLMMessage?) {
        let args = call.arguments
        switch call.name {
        case "web_search":
            return (await Toolbox.webSearch(query: jstr(args["query"])), nil)
        case "read_webpage":
            return (await Toolbox.readWebpage(urlString: jstr(args["url"])), nil)
        case "set_quiet":
            var minutes = 30.0
            if let d = args["minutes"] as? Double { minutes = d }
            else if let i = args["minutes"] as? Int { minutes = Double(i) }
            else if let s = args["minutes"] as? String, let d = Double(s) { minutes = d }
            applyQuiet(minutes: minutes)
            let msg = minutes > 0
                ? "Done — you won't start conversations for \(Int(minutes)) minutes."
                : "Done — proactive conversations re-enabled."
            return (msg, nil)
        case "look_at_screen":
            guard settings.screenEnabled else {
                return ("Screen access is disabled in settings.", nil)
            }
            // Live broadcast frame beats a screenshot
            if let b64 = ScreenWatch.shared.freshFrameB64() {
                if vision {
                    let extra = LLMMessage(
                        role: "user",
                        content: "[SYSTEM: live view of the user's screen right now (screen broadcast) — captured by the app, not typed by the user.]",
                        images: [b64]
                    )
                    return ("Live screen view captured.", extra)
                }
                return ("The screen broadcast is running, but the current brain has no vision support — tell the user to switch to Gemini, OpenAI, Claude, or a vision (👁) Ollama model to actually see it.", nil)
            }
            switch await ScreenPeek.latestScreenshot() {
            case .noPermission:
                return ("No Photos permission — the user must allow photo access in iPad Settings → Privacy & Security → Photos → AI Buddy.", nil)
            case .notFound:
                return ("No screenshot found. iPadOS doesn't let apps watch the screen directly — ask the user to take a screenshot (Top button + Volume Up together) and then ask you to look again.", nil)
            case .stale(let minutes):
                return ("The most recent screenshot is \(minutes) minutes old — probably not what they're doing right now. Ask the user to take a fresh screenshot (Top button + Volume Up) and ask you again.", nil)
            case .found(let b64, let age):
                let ageText = ScreenPeek.ageText(seconds: age)
                if vision {
                    let extra = LLMMessage(
                        role: "user",
                        content: "[SYSTEM: the user's most recent screenshot, taken \(ageText) ago — captured by the app, not typed by the user.]",
                        images: [b64]
                    )
                    return ("Screenshot fetched (taken \(ageText) ago).", extra)
                }
                return ("A screenshot from \(ageText) ago exists, but the current brain has no vision support — tell the user to switch to Gemini, OpenAI, Claude, or a vision (👁) Ollama model to actually see it.", nil)
            }
        default:
            return ("Unknown tool: \(call.name)", nil)
        }
    }

    // ------------------------------------------------------------- settings screen helpers

    func testConnection() async -> String {
        if settings.mode == "apple" {
            return AppleBrainFactory.statusLine()
        }
        if settings.mode == "gguf" {
            do {
                _ = try buildProvider(settings: settings, setQuiet: { _ in })
                return "Ready — \(settings.ggufModel) loads onto the GPU on the first message (first reply takes a few extra seconds)."
            } catch {
                return error.localizedDescription
            }
        }
        if settings.mode == "ollama" {
            do {
                let models = try await OllamaNativeProvider.listModels(base: settings.ollamaBase)
                if models.isEmpty { return "Connected, but no models are pulled on the PC." }
                return "Connected ✓ — models: " + models.map { $0.name }.joined(separator: ", ")
            } catch {
                return "Could not reach Ollama: \(error.localizedDescription)"
            }
        }
        do {
            let provider = try buildProvider(settings: settings, setQuiet: { _ in })
            var text = ""
            for try await ev in provider.stream(
                messages: [LLMMessage(role: "user", content: "Reply with the single word: ready")],
                tools: []
            ) {
                if case .text(let t) = ev { text += t }
                if text.count > 60 { break }
            }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "Connected, but got an empty reply." : "Connected ✓ — reply: \(t.prefix(60))"
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }

    // ------------------------------------------------------------- persistence

    private static func loadHistory() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: Paths.history) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    private func saveHistory() {
        let slim = messages.suffix(200).map { m -> ChatMessage in
            var c = m
            c.images = []   // images are too big to persist
            return c
        }
        if let data = try? JSONEncoder().encode(Array(slim)) {
            try? data.write(to: Paths.history)
        }
    }

    private static func loadSettings() -> BuddySettings {
        guard let data = try? Data(contentsOf: Paths.settings),
              let s = try? JSONDecoder().decode(BuddySettings.self, from: data) else {
            return BuddySettings()
        }
        return s
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: Paths.settings)
        }
    }
}

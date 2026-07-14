import Foundation
import AVFoundation

// Spoken replies via AVSpeechSynthesizer. Sentences are enqueued as they
// stream in (the synthesizer queues utterances natively); stopAll() is the
// interruption path.

@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    @Published var isSpeaking = false
    @Published var pulse: Double = 0     // pseudo-amplitude for the avatar

    private let synth = AVSpeechSynthesizer()
    private var pendingCount = 0
    private var voiceId = ""
    private var gender = "male"
    private var rate: Double = 0.5
    private var enabled = true
    private var speakingOffWork: DispatchWorkItem?
    private var settings = BuddySettings()

    override init() {
        super.init()
        synth.delegate = self
        // The shared manager owns the audio session so the output route stays
        // put when the mic toggles (earbuds stay earbuds, speaker stays speaker).
        AudioSessionManager.shared.ensureActive()
        SystemVoiceFallback.speaker = self
        CloneSpeaker.shared.onUtteranceDone = { [weak self] in self?.utteranceEnded() }
        CloneSpeaker.shared.onPulse = { [weak self] v in self?.pulse = v }
    }

    func configure(settings: BuddySettings) {
        self.settings = settings
        voiceId = settings.voiceIdentifier
        gender = settings.voiceGender
        rate = settings.speechRate
        enabled = settings.speakEnabled
        // Point the clone engine at the selected voice clip.
        if let clip = VoiceClipStore.shared.clip(named: settings.cloneVoiceFile) {
            CloneSpeaker.shared.configure(refFile: clip.file, refText: clip.referenceText)
        }
        if !enabled { stopAll() }
    }

    func enqueue(_ text: String) {
        guard enabled else { return }
        route(text)
    }

    /// Used by the settings "hear a sample" button — ignores the mute toggle.
    func speakSample(_ text: String) {
        route(text)
    }

    /// Send one sentence to the cloned voice when it's ready, else the system voice.
    private func route(_ text: String) {
        if CloneSpeaker.shared.isUsable(settings: settings) {
            cloneEnqueue(text)
        } else {
            speakSystem(text)
        }
    }

    private func cloneEnqueue(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if t.hasPrefix("{") && t.contains("\"name\"") { return }
        beginSpeaking()
        pendingCount += 1
        isSpeaking = true
        CloneSpeaker.shared.enqueue(t)
    }

    /// The Apple system-voice path — also the fallback when cloning can't run.
    func speakSystem(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if t.hasPrefix("{") && t.contains("\"name\"") { return }   // never read tool JSON aloud
        beginSpeaking()
        let u = AVSpeechUtterance(string: t)
        u.voice = pickVoice()
        u.rate = Float(rate)
        pendingCount += 1
        isSpeaking = true
        synth.speak(u)
    }

    func stopAll() {
        pendingCount = 0
        synth.stopSpeaking(at: .immediate)
        CloneSpeaker.shared.stopAll()
        isSpeaking = false
        pulse = 0
        speakingOffWork?.cancel()
        speakingOffWork = nil
        AudioSessionManager.shared.setSpeaking(false)
    }

    /// Mark the session as "playing" so it keeps A2DP output (and pauses the
    /// mic while earbuds are attached). Cancels any pending stop.
    private func beginSpeaking() {
        speakingOffWork?.cancel()
        speakingOffWork = nil
        AudioSessionManager.shared.setSpeaking(true)
    }

    /// Debounced so gaps between streamed sentences don't flap the mic on/off.
    private func endSpeakingSoon() {
        speakingOffWork?.cancel()
        let work = DispatchWorkItem { AudioSessionManager.shared.setSpeaking(false) }
        speakingOffWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // ------------------------------------------------------------- voices

    func pickVoice() -> AVSpeechSynthesisVoice? {
        if !voiceId.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceId) { return v }
        let want: AVSpeechSynthesisVoiceGender = gender == "female" ? .female : .male
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { Self.qualityRank($0) > Self.qualityRank($1) }
        return english.first(where: { $0.gender == want })
            ?? english.first
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func qualityRank(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    /// Voices offered in settings: English plus the device's languages.
    static func selectableVoices() -> [AVSpeechSynthesisVoice] {
        let langs = Set(["en"] + Locale.preferredLanguages.compactMap { $0.split(separator: "-").first.map(String.init) })
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { v in langs.contains(where: { v.language.hasPrefix($0) }) }
            .sorted { a, b in
                if a.language != b.language { return a.language < b.language }
                let qa = qualityRank(a), qb = qualityRank(b)
                if qa != qb { return qa > qb }
                return a.name < b.name
            }
    }

    // ------------------------------------------------------------- delegate

    // Delegate callbacks arrive on an arbitrary thread and satisfy a non-isolated
    // protocol, so they're `nonisolated` and hop to the main actor.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.pulse = 0.45 + Double.random(in: 0...0.45) }
    }

    private func utteranceEnded() {
        pendingCount = max(0, pendingCount - 1)
        if pendingCount <= 0 {
            isSpeaking = false
            pulse = 0
            endSpeakingSoon()
        }
    }
}

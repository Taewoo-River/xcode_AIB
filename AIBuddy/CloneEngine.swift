import Foundation
import AVFoundation

// Cloned-voice speaker: a serial generate→play pipeline in front of Qwen3-TTS.
// The Speaker routes sentences here when clone mode is on and everything's
// ready (model downloaded, a clip selected, app in the foreground). The
// MLX-dependent generation is isolated in `CloneCore` behind #if canImport.

@MainActor
final class CloneSpeaker: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = CloneSpeaker()

    /// Called (main) each time one queued utterance finishes or is dropped, so
    /// the Speaker can track how many are still pending.
    var onUtteranceDone: (() -> Void)?
    /// Rough amplitude for the avatar while a clip plays.
    var onPulse: ((Double) -> Void)?

    private var queue: [String] = []
    private var processing = false
    private var generation = 0
    private var player: AVAudioPlayer?
    private var refFile = ""
    private var refText = ""

    var isCompiledIn: Bool { CloneTTSAvailability.isCompiledIn }

    /// Whether we can actually speak with a cloned voice right now.
    func isUsable(settings: BuddySettings) -> Bool {
        guard isCompiledIn else { return false }
        guard settings.ttsEngine == "clone", !settings.cloneVoiceFile.isEmpty else { return false }
        guard CloneModelInfo.isReady() else { return false }
        if AppState.shared.isBackground { return false }   // Metal is blocked in background
        return true
    }

    func configure(refFile: String, refText: String) {
        self.refFile = refFile
        self.refText = refText
    }

    func enqueue(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queue.append(t)
        if !processing { processing = true; Task { await drain() } }
    }

    func stopAll() {
        generation += 1
        queue.removeAll()
        processing = false
        player?.stop()
        player = nil
        onPulse?(0)
    }

    // ------------------------------------------------------------- pipeline

    private func drain() async {
        let myGen = generation
        while true {
            if myGen != generation { return }
            guard !queue.isEmpty else { processing = false; return }
            let text = queue.removeFirst()
            await speakOne(text, myGen: myGen)
            onUtteranceDone?()
        }
    }

    private func speakOne(_ text: String, myGen: Int) async {
        #if canImport(Qwen3TTS)
        do {
            let samples = try await CloneCore.shared.generate(
                text: text,
                refWav: Paths.voices.appendingPathComponent(refFile),
                refText: refText
            )
            if myGen != generation { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("clone-\(UUID().uuidString).wav")
            try AudioTools.writeWav(samples, sampleRate: 24000, to: url)
            await playAndWait(url: url, myGen: myGen)
            try? FileManager.default.removeItem(at: url)
        } catch {
            // On any failure, fall back so the reply is still spoken.
            SystemVoiceFallback.speak(text)
        }
        #else
        SystemVoiceFallback.speak(text)
        #endif
    }

    private func playAndWait(url: URL, myGen: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            do {
                AudioSessionManager.shared.ensureActive()
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                player = p
                finishContinuation = cont
                onPulse?(0.6)
                p.play()
            } catch {
                cont.resume()
            }
        }
    }

    private var finishContinuation: CheckedContinuation<Void, Never>?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onPulse?(0)
        let c = finishContinuation
        finishContinuation = nil
        c?.resume()
    }
}

/// Small helper so the fallback path exists whether or not MLX is compiled in.
enum SystemVoiceFallback {
    @MainActor static var speaker: Speaker?   // set by BuddyEngine at init
    static func speak(_ text: String) {
        Task { @MainActor in speaker?.speakSystem(text) }
    }
}

// ------------------------------------------------------------------ MLX core (guarded)

#if canImport(Qwen3TTS)
import MLX
import Qwen3TTS

/// Serializes all MLX/Metal work and keeps the model + reference audio warm.
actor CloneCore {
    static let shared = CloneCore()

    private var model: Qwen3TTSModel?
    private var loadedRef = ""
    private var refAudio: MLXArray?

    func generate(text: String, refWav: URL, refText: String) async throws -> [Float] {
        if model == nil {
            model = try await Qwen3TTSModel.fromPretrained(CloneModelInfo.dir.path)
        }
        guard let model else { throw BuddyError("Clone model failed to load.") }
        guard model.supportsVoiceCloning else {
            throw BuddyError("This TTS model doesn't support voice cloning.")
        }
        if loadedRef != refWav.lastPathComponent || refAudio == nil {
            let (_, arr) = try loadAudioArray(from: refWav)
            refAudio = arr
            loadedRef = refWav.lastPathComponent
        }
        guard let refAudio else { throw BuddyError("Reference audio not loaded.") }
        let audio = try model.generateVoiceClone(
            text: text,
            referenceAudio: refAudio,
            referenceText: refText,
            language: "auto",
            temperature: 0.9,
            topK: 50,
            maxTokens: 2048
        )
        eval(audio)
        return audio.asArray(Float.self)
    }
}
#endif

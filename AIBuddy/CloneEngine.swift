import Foundation
import AVFoundation

// Cloned-voice speaker: a serial generate→play pipeline in front of the active
// cloning engine (sherpa-onnx + ZipVoice, CPU/ONNX). The Speaker routes
// sentences here when clone mode is on and everything's ready. Unlike the local
// LLM this runs on the CPU, so it also works in the background.
//
// A dormant Qwen3-TTS/MLX path is kept at the bottom behind #if canImport(Qwen3TTS)
// for when that dependency chain is buildable again — flip `useMLXInstead`.

@MainActor
final class CloneSpeaker: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = CloneSpeaker()

    /// Called (main) each time one queued utterance finishes, so the Speaker can
    /// track how many are still pending.
    var onUtteranceDone: (@MainActor () -> Void)?
    /// Rough amplitude for the avatar while a clip plays.
    var onPulse: (@MainActor (Double) -> Void)?
    /// Why the last utterance fell back to the system voice (shown in settings).
    @Published var lastError: String?

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
        return CloneModelInfo.isReady()
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
            // Coalesce queued sentences into one generation (up to ~220 chars):
            // ZipVoice re-encodes the reference clip on every call, so fewer,
            // larger calls save real compute and reduce inter-sentence gaps.
            var text = queue.removeFirst()
            var joined = 1
            while let next = queue.first, text.count + next.count < 220 {
                text += " " + next
                queue.removeFirst()
                joined += 1
            }
            await speakOne(text, myGen: myGen)
            for _ in 0..<joined { onUtteranceDone?() }
        }
    }

    private func speakOne(_ text: String, myGen: Int) async {
        do {
            let refWav = Paths.voices.appendingPathComponent(refFile)
            let (samples, sampleRate) = try await SherpaCloneCore.shared.generate(
                text: text, refWav: refWav, refText: refText
            )
            if myGen != generation { return }
            guard !samples.isEmpty else {
                lastError = "Generation produced no audio."
                SystemVoiceFallback.speak(text)
                return
            }
            lastError = nil
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("clone-\(UUID().uuidString).wav")
            try AudioTools.writeWav(samples, sampleRate: sampleRate, to: url)
            await playAndWait(url: url, myGen: myGen)
            try? FileManager.default.removeItem(at: url)
        } catch {
            // On any failure, fall back so the reply is still spoken — and keep
            // the reason so the settings screen can show it.
            lastError = error.localizedDescription
            SystemVoiceFallback.speak(text)
        }
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

    // Delegate callback arrives on an arbitrary thread and satisfies a
    // non-isolated protocol, so it's `nonisolated` and hops to the main actor.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.onPulse?(0)
            let c = self.finishContinuation
            self.finishContinuation = nil
            c?.resume()
        }
    }
}

/// Fallback so a reply is always spoken even if cloning fails.
enum SystemVoiceFallback {
    @MainActor static var speaker: Speaker?   // set by Speaker at init
    static func speak(_ text: String) {
        Task { @MainActor in speaker?.speakSystem(text) }
    }
}

// ------------------------------------------------------------------ sherpa core (active)
// Serializes sherpa-onnx access; keeps the TTS model + reference audio warm.

actor SherpaCloneCore {
    static let shared = SherpaCloneCore()

    private var tts: SherpaOnnxOfflineTtsWrapper?
    private var loadedRef = ""
    private var refSamples: [Float] = []
    private var refSampleRate: Int = 24000

    func generate(text: String, refWav: URL, refText: String) throws -> (samples: [Float], sampleRate: Int) {
        // ZipVoice needs the reference transcript — an empty one can crash the
        // native engine, so refuse cleanly (caller falls back to system voice).
        let refT = refText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refT.isEmpty else {
            throw BuddyError("The voice clip has no transcript — tap ✏️ next to it and type what the clip says.")
        }
        // A partial extraction makes espeak-ng abort the whole app — verify the
        // pieces exist before handing paths to native code.
        let fm = FileManager.default
        let phontab = CloneModelInfo.dir.appendingPathComponent("espeak-ng-data/phontab").path
        guard fm.fileExists(atPath: CloneModelInfo.encoder),
              fm.fileExists(atPath: CloneModelInfo.decoder),
              fm.fileExists(atPath: CloneModelInfo.tokens),
              fm.fileExists(atPath: CloneModelInfo.vocoder),
              fm.fileExists(atPath: phontab) else {
            throw BuddyError("The voice model looks incomplete — re-download it in Cloned voices (the update added a required vocoder file).")
        }

        if tts == nil {
            // Keep the path strings alive through SherpaOnnxCreateOfflineTts.
            let tokens = CloneModelInfo.tokens
            let encoder = CloneModelInfo.encoder
            let decoder = CloneModelInfo.decoder
            let dataDir = CloneModelInfo.dataDir
            let lexicon = CloneModelInfo.lexicon
            let vocoder = CloneModelInfo.vocoder
            let threads = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
            let zip = sherpaOnnxOfflineTtsZipvoiceModelConfig(
                tokens: tokens, encoder: encoder, decoder: decoder, vocoder: vocoder,
                dataDir: dataDir, lexicon: lexicon
            )
            let model = sherpaOnnxOfflineTtsModelConfig(numThreads: threads, provider: "cpu", zipvoice: zip)
            var cfg = sherpaOnnxOfflineTtsConfig(model: model)
            let wrapper = withUnsafePointer(to: &cfg) { SherpaOnnxOfflineTtsWrapper(config: $0) }
            // The C constructor returns NULL on a bad model; the wrapper stores it
            // in an implicitly-unwrapped pointer that would crash on first use.
            guard wrapper.tts != nil else {
                throw BuddyError("The voice engine couldn't load the model — delete and re-download it in Cloned voices.")
            }
            tts = wrapper
        }
        guard let tts else { throw BuddyError("Voice engine failed to load.") }

        // The reference clip samples are cached here; the loaded model is kept
        // warm too, so repeat generations only pay for the synthesis itself.
        if loadedRef != refWav.lastPathComponent || refSamples.isEmpty {
            let (s, sr) = try AudioTools.loadFloats(url: refWav)
            refSamples = s
            refSampleRate = sr
            loadedRef = refWav.lastPathComponent
        }
        guard !refSamples.isEmpty else { throw BuddyError("Reference clip is empty.") }

        var gcfg = SherpaOnnxGenerationConfigSwift()
        gcfg.referenceAudio = refSamples
        gcfg.referenceSampleRate = refSampleRate
        gcfg.referenceText = refT
        gcfg.numSteps = 4
        gcfg.extra = ["min_char_in_sentence": 10]   // matches sherpa's own example
        let audio = tts.generateWithConfig(text: text, config: gcfg, callback: nil, arg: nil)
        guard audio.audio != nil else {
            throw BuddyError("Voice generation failed — try re-importing the clip or re-downloading the model.")
        }
        return (audio.samples, Int(audio.sampleRate))
    }

    /// Drop the loaded engine (e.g. after the model is deleted/re-downloaded).
    func unload() {
        tts = nil
        loadedRef = ""
        refSamples = []
    }
}

// ------------------------------------------------------------------ MLX core (dormant)
// Re-enable by restoring the swift-qwen3-tts package (see project.yml) — then
// route speakOne() through this instead of SherpaCloneCore.

#if canImport(Qwen3TTS)
import MLX
import Qwen3TTS

actor CloneCoreMLX {
    static let shared = CloneCoreMLX()
    private var model: Qwen3TTSModel?
    private var loadedRef = ""
    private var refAudio: MLXArray?

    func generate(text: String, refWav: URL, refText: String) async throws -> [Float] {
        if model == nil {
            model = try await Qwen3TTSModel.fromPretrained(Paths.models.appendingPathComponent("qwen3-tts-base").path)
        }
        guard let model, model.supportsVoiceCloning else { throw BuddyError("MLX clone model unavailable.") }
        if loadedRef != refWav.lastPathComponent || refAudio == nil {
            let (_, arr) = try loadAudioArray(from: refWav)
            refAudio = arr
            loadedRef = refWav.lastPathComponent
        }
        guard let refAudio else { throw BuddyError("Reference audio not loaded.") }
        let audio = try model.generateVoiceClone(
            text: text, referenceAudio: refAudio, referenceText: refText,
            language: "auto", temperature: 0.9, topK: 50, maxTokens: 2048
        )
        eval(audio)
        return audio.asArray(Float.self)
    }
}
#endif

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

    // Two-stage pipeline: sentence N+1 is SYNTHESIZED while sentence N PLAYS,
    // which removes the audible gap between sentences (generation is roughly
    // real-time on the CPU, so overlapping hides it almost entirely).
    private var textQueue: [String] = []
    private var wavQueue: [URL] = []
    private var generating = false
    private var playing = false
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
        // Cap per-generation length: very long inputs crash the native engine.
        // When idle, use a shorter first chunk so the first audio arrives sooner.
        let idle = !generating && !playing && wavQueue.isEmpty && textQueue.isEmpty
        for piece in Self.chunks(of: t, limit: idle ? 90 : 180) {
            textQueue.append(piece)
        }
        pumpGenerate()
    }

    /// Split text into ≤limit-char pieces at natural pauses (punctuation/space).
    static func chunks(of s: String, limit: Int) -> [String] {
        guard s.count > limit else { return [s] }
        var out: [String] = []
        var rest = Substring(s)
        let pauses = Set(",;:、，。.!?！？ \n")
        while rest.count > limit {
            let window = rest.prefix(limit)
            if let cut = window.lastIndex(where: { pauses.contains($0) }) {
                out.append(String(rest[...cut]).trimmingCharacters(in: .whitespaces))
                rest = rest[rest.index(after: cut)...]
            } else {
                out.append(String(window))
                rest = rest.dropFirst(limit)
            }
        }
        let tail = String(rest).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out.filter { !$0.isEmpty }
    }

    func stopAll() {
        generation += 1
        textQueue.removeAll()
        for u in wavQueue { try? FileManager.default.removeItem(at: u) }
        wavQueue.removeAll()
        player?.stop()
        player = nil
        // AVAudioPlayer.stop() does NOT fire the delegate — resume the waiter
        // manually or the pipeline (and the Speaker's pendingCount) hangs
        // forever, which also kept the mic from ever resuming.
        finishContinuation?.resume()
        finishContinuation = nil
        onPulse?(0)
    }

    // ------------------------------------------------------------- stage 1: synthesize

    private func pumpGenerate() {
        guard !generating, !textQueue.isEmpty else { return }
        generating = true
        // Coalesce what's already queued (ZipVoice re-encodes the reference on
        // every call) — the FIRST sentence is never delayed by this because it
        // is alone in the queue when it arrives.
        var text = textQueue.removeFirst()
        var joined = 1
        while let next = textQueue.first, text.count + next.count < 220 {
            text += " " + next
            textQueue.removeFirst()
            joined += 1
        }
        let myGen = generation
        Task {
            var wav: URL? = nil
            do {
                let refWav = Paths.voices.appendingPathComponent(refFile)
                let (samples, sampleRate) = try await SherpaCloneCore.shared.generate(
                    text: text, refWav: refWav, refText: refText
                )
                if !samples.isEmpty {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("clone-\(UUID().uuidString).wav")
                    // Lead-in silence so the audio route can settle before the
                    // first syllable — otherwise it gets clipped.
                    let padded = [Float](repeating: 0, count: sampleRate / 4) + samples
                    try AudioTools.writeWav(padded, sampleRate: sampleRate, to: url)
                    wav = url
                    lastError = nil
                } else {
                    lastError = "Generation produced no audio."
                }
            } catch {
                lastError = error.localizedDescription
            }
            self.generating = false
            guard myGen == self.generation else {
                if let wav { try? FileManager.default.removeItem(at: wav) }
                return
            }
            if let wav {
                self.wavQueue.append(wav)
                // the blob counts as ONE playback; settle the extra merged ones now
                for _ in 0..<(joined - 1) { self.onUtteranceDone?() }
                self.pumpPlay()
            } else {
                SystemVoiceFallback.speak(text)
                for _ in 0..<joined { self.onUtteranceDone?() }
            }
            self.pumpGenerate()
        }
    }

    // ------------------------------------------------------------- stage 2: play

    private func pumpPlay() {
        guard !playing, !wavQueue.isEmpty else { return }
        playing = true
        let url = wavQueue.removeFirst()
        let myGen = generation
        Task {
            await playAndWait(url: url)
            try? FileManager.default.removeItem(at: url)
            self.playing = false
            self.onUtteranceDone?()
            if myGen == self.generation { self.pumpPlay() }
        }
    }

    private func playAndWait(url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            do {
                // Only NOW does audio actually play — this is the point where the
                // mic must yield on Bluetooth. During LLM generation + synthesis
                // it stays live, so voice interruption works until audio starts.
                AudioSessionManager.shared.setSpeaking(true)
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

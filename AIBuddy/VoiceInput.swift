import Foundation
import AVFoundation
import Speech

// Continuous voice input: auto-detects when you start and stop speaking
// (like the PC version's VAD + faster-whisper, but with Apple's on-device
// speech recognition). Fires onSpeechDetected the moment speech starts so
// the engine can barge-in-interrupt the buddy.

final class VoiceInput: ObservableObject {

    @Published var armed = false
    @Published var level: Double = 0        // 0..1 mic amplitude for the avatar
    @Published var preview = ""             // live partial transcript
    @Published var authProblem: String? = nil

    var onFinalUtterance: ((String) -> Void)?
    var onSpeechDetected: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastChange = Date()
    private var endpointTimer: Timer?
    private var restartPending = false

    private var silenceMs: Double = 950
    private var onDevice = true
    private var localeId = "en-US"
    private var lastBufferAt = Date()   // watchdog: detects a deaf (running but silent) engine

    func configure(settings: BuddySettings) {
        silenceMs = settings.silenceMs
        onDevice = settings.onDeviceRecognition
        localeId = settings.sttLocale
    }

    func setArmed(_ on: Bool) {
        if on { start() } else { stop() }
    }

    // ------------------------------------------------------------- lifecycle

    private func start() {
        guard !armed else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.authProblem = "Speech recognition permission denied — enable it in Settings → Privacy → Speech Recognition."
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.authProblem = "Microphone permission denied — enable it in Settings → Privacy → Microphone."
                            return
                        }
                        self.reallyStart()
                    }
                }
            }
        }
    }

    private func reallyStart() {
        armed = true
        AppState.shared.micArmed = true   // grants CPU background inference
        authProblem = nil
        // The session manager drives the actual engine on/off: it pauses the mic
        // while the buddy speaks through earbuds (so replies keep A2DP output),
        // then resumes listening. setRecording(true) triggers the first start.
        AudioSessionManager.shared.onMicActiveChange = { [weak self] active in
            DispatchQueue.main.async { self?.setEngineActive(active) }
        }
        AudioSessionManager.shared.setRecording(true)
        endpointTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.checkEndpoint()
        }
    }

    func stop() {
        armed = false
        AppState.shared.micArmed = false
        endpointTimer?.invalidate()
        endpointTimer = nil
        setEngineActive(false)
        AudioSessionManager.shared.onMicActiveChange = nil
        // Back to the playback session so output keeps flowing to earbuds.
        AudioSessionManager.shared.setRecording(false)
    }

    /// Start or stop the audio engine + recognition WITHOUT changing `armed`.
    /// Called by AudioSessionManager as the session flips record↔playback.
    private func setEngineActive(_ active: Bool) {
        if active {
            guard armed, !audioEngine.isRunning else { return }
            let input = audioEngine.inputNode
            // Echo-cancel the buddy's own voice so barge-in works — but only on
            // the built-in speaker. Voice-processing I/O forces output to the
            // speaker and blocks Bluetooth A2DP, so with earbuds we skip it.
            try? input.setVoiceProcessingEnabled(!AudioRoute.hasExternalOutput)
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.request?.append(buffer)
                let rms = VoiceInput.rms(buffer)
                DispatchQueue.main.async {
                    self.level = min(1, Double(rms) * 18)
                    self.lastBufferAt = Date()
                }
            }
            audioEngine.prepare()
            do { try audioEngine.start() } catch {
                authProblem = "Microphone error: \(error.localizedDescription)"
                return
            }
            lastBufferAt = Date()
            startSegment()
        } else {
            task?.cancel()
            task = nil
            request?.endAudio()
            request = nil
            preview = ""
            level = 0
            audioEngine.inputNode.removeTap(onBus: 0)
            if audioEngine.isRunning { audioEngine.stop() }
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return sqrtf(sum / Float(n))
    }

    // ------------------------------------------------------------- recognition segments

    private func startSegment() {
        task?.cancel()
        task = nil
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        let rec = SFSpeechRecognizer(locale: Locale(identifier: localeId)) ?? SFSpeechRecognizer()
        recognizer = rec
        if onDevice, rec?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        preview = ""
        lastChange = Date()
        task = rec?.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(result: result, error: error) }
        }
        if task == nil {
            authProblem = "Speech recognition is unavailable for \(localeId)."
            stop()
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard armed, task != nil else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if text != preview {
                if preview.isEmpty && !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    onSpeechDetected?()
                }
                preview = text
                lastChange = Date()
            }
            if result.isFinal {
                finalize()
                return
            }
        }
        if error != nil {
            if !preview.trimmingCharacters(in: .whitespaces).isEmpty {
                finalize()
            } else {
                task?.cancel()
                task = nil
                request = nil
                scheduleRestart()
            }
        }
    }

    private func checkEndpoint() {
        // Watchdog: engine claims to run but no audio buffers arrive → the tap
        // captured a stale route format and went deaf. Bounce it automatically
        // (this used to require toggling the mic button by hand).
        if armed, audioEngine.isRunning, AudioSessionManager.shared.micShouldRun,
           Date().timeIntervalSince(lastBufferAt) > 3 {
            setEngineActive(false)
            setEngineActive(true)
            return
        }
        guard armed, !preview.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if Date().timeIntervalSince(lastChange) * 1000 >= silenceMs {
            finalize()
        }
    }

    private func finalize() {
        let text = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        preview = ""
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if !text.isEmpty { onFinalUtterance?(text) }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard armed, !restartPending else { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            if self.armed && self.task == nil { self.startSegment() }
        }
    }
}

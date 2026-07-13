import Foundation
import AVFoundation

// One place that owns the shared AVAudioSession so the output route never
// jumps around. The subtlety that fixes earbuds:
//
//   `.playAndRecord` (needed for the mic) SUSPENDS Bluetooth A2DP, so output
//   falls back to the iPad speaker while the mic is active. That's why replies
//   came out of the speaker once you'd used voice input.
//
// So while the buddy is SPEAKING through earbuds we drop to `.playback` (which
// keeps high-quality A2DP output) and briefly pause the mic; the moment it
// finishes we switch back to `.playAndRecord` and resume listening. On the
// built-in speaker there's nothing to protect, so we keep recording throughout
// (so voice barge-in still works there).

enum AudioRoute {
    /// True when headphones / earbuds / Bluetooth / AirPlay output is attached.
    static var hasExternalOutput: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { out in
            switch out.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP,
                 .airPlay, .usbAudio, .carAudio, .lineOut:
                return true
            default:
                return false
            }
        }
    }
}

final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private var recording = false   // mic armed
    private var speaking = false    // TTS playing
    private var observing = false
    private var lastEffectiveRecording: Bool? = nil

    /// VoiceInput registers this; called with `true` to (re)start the mic engine
    /// and `false` to pause it when the session flips to playback.
    var onMicActiveChange: ((Bool) -> Void)?

    func setRecording(_ on: Bool) { recording = on; apply() }
    func setSpeaking(_ on: Bool) { speaking = on; apply() }
    func ensureActive() { apply() }

    /// Whether the mic engine should actually be running right now.
    var micShouldRun: Bool { effectiveRecording }

    private var effectiveRecording: Bool {
        // Speaking through earbuds → yield the mic so A2DP output is kept.
        if recording && speaking && AudioRoute.hasExternalOutput { return false }
        return recording
    }

    private func apply() {
        startObservingRouteChanges()
        let session = AVAudioSession.sharedInstance()
        let eff = effectiveRecording

        // Pausing the mic: stop the engine BEFORE we leave .playAndRecord.
        if lastEffectiveRecording == true && eff == false {
            onMicActiveChange?(false)
        }

        do {
            if eff {
                var opts: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .allowBluetooth]
                if !AudioRoute.hasExternalOutput { opts.insert(.defaultToSpeaker) }
                try session.setCategory(.playAndRecord, mode: .default, options: opts)
            } else {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
        } catch {
            // transient; self-corrects on the next apply()
        }

        // Resuming the mic: start the engine AFTER .playAndRecord is in effect.
        if lastEffectiveRecording != true && eff == true {
            onMicActiveChange?(true)
        }
        lastEffectiveRecording = eff
    }

    private func startObservingRouteChanges() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.apply()   // earbuds plugged/pulled → re-decide routing
        }
    }
}

import Foundation
import AVFoundation

// One place that owns the shared AVAudioSession so the output route never
// jumps around. The rule that fixes earbuds:
//   • not recording  → .playback              (routes to earbuds like Safari)
//   • recording (mic)→ .playAndRecord         (needs the mic)
//   • force the built-in speaker ONLY when no earbuds/headphones are attached,
//     so connected earbuds always receive output in BOTH states — no flapping.

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

    private var recording = false
    private var observing = false

    /// Called by VoiceInput when the mic arms/disarms.
    func setRecording(_ on: Bool) {
        recording = on
        apply()
    }

    /// Called by Speaker before it speaks, to make sure the session is live.
    func ensureActive() {
        apply()
    }

    private func apply() {
        startObservingRouteChanges()
        let session = AVAudioSession.sharedInstance()
        do {
            if recording {
                // .allowBluetoothA2DP keeps high-quality earbud output; add
                // .defaultToSpeaker only when nothing is plugged in so the
                // loud bottom speaker (not the quiet one) is used.
                var opts: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .allowBluetooth]
                if !AudioRoute.hasExternalOutput { opts.insert(.defaultToSpeaker) }
                try session.setCategory(.playAndRecord, mode: .default, options: opts)
            } else {
                // .playback routes to earbuds exactly like other media apps.
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
        } catch {
            // A transient failure (e.g. mid route-change) self-corrects on the
            // next apply(); nothing actionable here.
        }
    }

    private func startObservingRouteChanges() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Earbuds plugged in or pulled out → re-decide .defaultToSpeaker.
            self?.apply()
        }
    }
}

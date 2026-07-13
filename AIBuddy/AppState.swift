import Foundation

// Thread-safe foreground/background flag, readable from the llama.cpp worker
// thread. iOS blocks GPU (Metal) execution while an app is backgrounded, so the
// on-device GGUF model must not attempt a decode there — it would fail and leave
// the Metal context wedged. BuddyEngine keeps this in sync with scenePhase.

final class AppState: @unchecked Sendable {
    static let shared = AppState()
    private let lock = NSLock()
    private var _background = false

    var isBackground: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _background }
        set { lock.lock(); _background = newValue; lock.unlock() }
    }
}

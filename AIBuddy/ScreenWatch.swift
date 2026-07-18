import Foundation
import Network
import SwiftUI
import ReplayKit

// Receives live screen frames from the broadcast extension (localhost TCP,
// length-prefixed JPEGs) and keeps the newest one for the look_at_screen tool
// and proactive peeks. The listener costs nothing while no broadcast runs.

final class ScreenWatch: ObservableObject {
    static let shared = ScreenWatch()
    static let port: UInt16 = 48910   // must match Broadcast/SampleHandler.swift

    @Published var isWatching = false
    /// True once the broadcast extension has EVER connected this app run —
    /// distinguishes "user never started a broadcast / extension missing"
    /// from "broadcast ran earlier but stopped".
    @Published private(set) var everConnected = false
    private(set) var latestJPEG: Data? = nil
    private(set) var lastFrameAt: Date? = nil

    private var listener: NWListener?
    private var staleTimer: Timer?

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] connection in
                self?.everConnected = true
                connection.start(queue: .main)
                self?.receiveHeader(on: connection)
            }
            l.start(queue: .main)
            listener = l
        } catch {
            // port busy (stale instance) — the extension will just fail to
            // connect; a relaunch of the app clears it
        }
        staleTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let fresh = (self.lastFrameAt.map { Date().timeIntervalSince($0) < 8 }) ?? false
                if self.isWatching != fresh { self.isWatching = fresh }
            }
        }
    }

    /// Newest frame if the broadcast delivered one recently, as base64 JPEG.
    func freshFrameB64(maxAge: TimeInterval = 8) -> String? {
        guard let data = latestJPEG, let at = lastFrameAt,
              Date().timeIntervalSince(at) <= maxAge else { return nil }
        return data.base64EncodedString()
    }

    // ------------------------------------------------------------- framing

    private func receiveHeader(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, data.count == 4 else {
                connection.cancel()
                return
            }
            let b = [UInt8](data)
            let length = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            guard length > 0, length < 5_000_000 else {
                connection.cancel()
                return
            }
            self.receiveBody(on: connection, length: length)
        }
    }

    private func receiveBody(on connection: NWConnection, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, data.count == length else {
                connection.cancel()
                return
            }
            self.latestJPEG = data
            self.lastFrameAt = Date()
            if !self.isWatching { self.isWatching = true }
            self.receiveHeader(on: connection)
        }
    }
}

// ------------------------------------------------------------------ start/stop button
// Apple requires the system broadcast picker — apps can't start capture
// themselves. The picker's own button is unstylable and its hit-testing is
// unreliable inside SwiftUI, so we keep the picker hidden in the hierarchy and
// trigger its internal UIButton programmatically from our own visible button.

final class BroadcastPickerProxy {
    weak var picker: RPSystemBroadcastPickerView?

    func trigger() {
        guard let picker else { return }
        for case let button as UIButton in picker.subviews {
            button.sendActions(for: .touchUpInside)
            return
        }
        // fallback: search one level deeper in case the hierarchy changes
        for sub in picker.subviews {
            for case let button as UIButton in sub.subviews {
                button.sendActions(for: .touchUpInside)
                return
            }
        }
    }
}

private struct BroadcastPickerHost: UIViewRepresentable {
    let proxy: BroadcastPickerProxy

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        picker.preferredExtension = "com.taewoo.aibuddy.broadcast"
        picker.showsMicrophoneButton = false
        proxy.picker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        proxy.picker = uiView
    }
}

/// Visible record button that opens the system broadcast picker.
struct BroadcastPickerButton: View {
    @ObservedObject var watch = ScreenWatch.shared
    private let proxy = BroadcastPickerProxy()

    var body: some View {
        Button {
            proxy.trigger()
        } label: {
            Image(systemName: "inset.filled.rectangle.badge.record")
                .font(.title3)
                .foregroundStyle(watch.isWatching ? .green : .cyan)
                .frame(width: 34, height: 34)
        }
        .background(
            BroadcastPickerHost(proxy: proxy)
                .frame(width: 34, height: 34)
                .opacity(0.02)
                .allowsHitTesting(false)
        )
    }
}

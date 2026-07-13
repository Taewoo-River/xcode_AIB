import ReplayKit
import CoreImage
import ImageIO
import Network

// Broadcast Upload Extension: iPadOS runs this while the user has a screen
// broadcast active (started from the in-app button or Control Center).
// It downscales ~1 frame every 2 seconds to JPEG and streams it to the main
// app over localhost — the free-Apple-ID-friendly alternative to App Groups.

let framePort: UInt16 = 48910

class SampleHandler: RPBroadcastSampleHandler {

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastSent = Date.distantPast
    private var connection: NWConnection?
    private var connecting = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        connect()
    }

    override func broadcastFinished() {
        connection?.cancel()
        connection = nil
    }

    private func connect() {
        guard !connecting else { return }
        connecting = true
        let c = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: framePort)!,
            using: .tcp
        )
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.connecting = false
            case .failed, .cancelled:
                self?.connection = nil
                self?.connecting = false
            default:
                break
            }
        }
        connection = c
        c.start(queue: .global(qos: .utility))
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= 2.0 else { return }
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if connection == nil { connect() }
        guard let c = connection, c.state == .ready else { return }
        lastSent = now

        var ci = CIImage(cvPixelBuffer: px)
        // respect the screen's orientation so the model doesn't see it sideways
        if let attachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil),
           let number = attachment as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value) {
            ci = ci.oriented(orientation)
        }
        let longest = max(ci.extent.width, ci.extent.height)
        if longest > 900 {
            let scale = 900 / longest
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = ciContext.jpegRepresentation(
            of: ci,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [quality: 0.5]
        ) else { return }

        // length-prefixed frame packet
        var length = UInt32(jpeg.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(jpeg)
        c.send(content: packet, completion: .contentProcessed { _ in })
    }
}

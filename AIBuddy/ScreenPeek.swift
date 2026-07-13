import Foundation
import Photos
import UIKit

// The iPad's closest legal equivalent of the PC version's screen capture:
// fetch the user's most recent screenshot from Photos. (True live capture of
// other apps needs a ReplayKit broadcast extension, which Swift Playgrounds
// projects can't contain — that path needs an Xcode build on a Mac.)

enum ScreenPeek {

    enum PeekResult {
        case noPermission
        case notFound
        case stale(minutes: Int)
        case found(b64: String, ageSeconds: Int)
    }

    static func latestScreenshot(maxAgeSeconds: Double = 600) async -> PeekResult {
        let status = await withCheckedContinuation { c in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { return .noPermission }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        opts.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: .image, options: opts).firstObject else {
            return .notFound
        }
        let age = Date().timeIntervalSince(asset.creationDate ?? .distantPast)
        if age > maxAgeSeconds {
            return .stale(minutes: max(1, Int(age / 60)))
        }

        let image: UIImage? = await withCheckedContinuation { c in
            let ro = PHImageRequestOptions()
            ro.deliveryMode = .highQualityFormat   // guarantees a single callback
            ro.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1600, height: 1600),
                contentMode: .aspectFit,
                options: ro
            ) { img, _ in
                c.resume(returning: img)
            }
        }
        guard let image, let b64 = ChatView.jpegBase64(image) else { return .notFound }
        return .found(b64: b64, ageSeconds: max(1, Int(age)))
    }

    static func ageText(seconds: Int) -> String {
        seconds < 90 ? "\(seconds) seconds" : "\(max(1, seconds / 60)) minutes"
    }
}

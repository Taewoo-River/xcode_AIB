import Foundation
import SWCompression

// Thin wrapper over SWCompression so the voice-model tarball (.tar.bz2) can be
// unpacked on-device (Apple's Compression framework has no bzip2). Isolated
// here so the dependency's API lives in one place.

enum CloneArchive {
    struct Entry {
        let name: String
        let isDirectory: Bool
        let data: Data?
    }

    static func bunzip(_ data: Data) throws -> Data {
        try BZip2.decompress(data: data)
    }

    static func tarEntries(_ tar: Data) throws -> [Entry] {
        try TarContainer.open(container: tar).map { e in
            Entry(name: e.info.name, isDirectory: e.info.type == .directory, data: e.data)
        }
    }
}

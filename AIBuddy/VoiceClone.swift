import Foundation
import AVFoundation
import Speech

// Zero-shot voice cloning via Qwen3-TTS (MLX). Import a short clip of a voice +
// its transcript; the buddy then speaks in that voice. Runs on the Metal GPU,
// so — like the local LLM — it's foreground-only; in the background (or if the
// model/clip isn't ready) the Speaker falls back to the system voice.
//
// The MLX-dependent engine lives behind `#if canImport(Qwen3TTS)` so the app
// still builds if that package is ever removed.

// ------------------------------------------------------------------ voice clips

struct VoiceClip: Codable, Identifiable, Equatable {
    var id: String { file }
    var file: String        // 24 kHz mono WAV in Documents/voices/
    var name: String        // display name
    var referenceText: String
}

@MainActor
final class VoiceClipStore: ObservableObject {
    static let shared = VoiceClipStore()

    @Published var clips: [VoiceClip] = []
    @Published var importing = false
    @Published var importError: String?

    private var indexURL: URL { Paths.voices.appendingPathComponent("clips.json") }

    init() {
        try? FileManager.default.createDirectory(at: Paths.voices, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([VoiceClip].self, from: data) else { return }
        clips = list.filter { FileManager.default.fileExists(atPath: Paths.voices.appendingPathComponent($0.file).path) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(clips) { try? data.write(to: indexURL) }
    }

    func clip(named file: String) -> VoiceClip? { clips.first { $0.file == file } }

    func delete(_ clip: VoiceClip) {
        try? FileManager.default.removeItem(at: Paths.voices.appendingPathComponent(clip.file))
        clips.removeAll { $0.file == clip.file }
        save()
    }

    /// Import an audio file: resample to 24 kHz mono WAV, auto-transcribe the
    /// reference text, and register it. Long clips are trimmed to ~15 s.
    func importClip(from sourceURL: URL, name: String) {
        importing = true
        importError = nil
        Task {
            do {
                let base = "voice-\(UUID().uuidString.prefix(8)).wav"
                let dest = Paths.voices.appendingPathComponent(base)
                try await AudioTools.resampleToWav24k(from: sourceURL, to: dest, maxSeconds: 15)
                let text = (try? await AudioTools.transcribe(url: dest)) ?? ""
                await MainActor.run {
                    self.clips.append(VoiceClip(file: base, name: name.isEmpty ? "Cloned voice" : name, referenceText: text))
                    self.save()
                    self.importing = false
                }
            } catch {
                await MainActor.run {
                    self.importError = "Couldn't import that audio: \(error.localizedDescription)"
                    self.importing = false
                }
            }
        }
    }

    func updateText(_ clip: VoiceClip, text: String) {
        guard let i = clips.firstIndex(where: { $0.file == clip.file }) else { return }
        clips[i].referenceText = text
        save()
    }
}

// ------------------------------------------------------------------ audio helpers

enum AudioTools {
    /// Convert any decodable audio file to a mono 24 kHz 16-bit WAV, trimmed to
    /// `maxSeconds`. Uses AVAudioConverter for resampling.
    static func resampleToWav24k(from src: URL, to dst: URL, maxSeconds: Double) async throws {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let inFile = try AVAudioFile(forReading: src)
        let inFormat = inFile.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw BuddyError("Unsupported audio format.")
        }

        let capacity: AVAudioFrameCount = 16384
        var collected: [Float] = []
        let maxFrames = Int(24000 * maxSeconds)

        while true {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: capacity) else { break }
            try inFile.read(into: inBuf)
            if inBuf.frameLength == 0 { break }
            let ratio = 24000.0 / inFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { break }
            var err: NSError?
            var supplied = false
            converter.convert(to: outBuf, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return inBuf
            }
            if let err { throw err }
            if let ch = outBuf.floatChannelData {
                collected.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
            }
            if collected.count >= maxFrames { collected = Array(collected.prefix(maxFrames)); break }
        }
        guard !collected.isEmpty else { throw BuddyError("The audio clip was empty.") }
        try writeWav(collected, sampleRate: 24000, to: dst)
    }

    /// Write mono Float samples as a 16-bit PCM WAV.
    static func writeWav(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + samples.count * 2)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(samples.count * 2))
        for s in samples {
            let c = max(-1, min(1, s))
            u16(UInt16(bitPattern: Int16(c * 32767)))
        }
        try data.write(to: url)
    }

    /// On-device transcription of a WAV file (for the reference transcript).
    static func transcribe(url: URL) async throws -> String {
        let ok = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard ok, let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), rec.isAvailable else {
            return ""
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        return try await withCheckedThrowingContinuation { cont in
            rec.recognitionTask(with: req) { result, error in
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

// ------------------------------------------------------------------ model download
// The Base cloning model is a directory of files (config + safetensors) on
// ModelScope. We fetch the file list, then download each into one folder.

// Nonisolated model info, safe to read from the MLX actor and the speaker.
enum CloneModelInfo {
    static let repo = "Qwen/Qwen3-TTS-12Hz-0.6B-Base"
    static var dir: URL { Paths.models.appendingPathComponent("qwen3-tts-base", isDirectory: true) }

    /// Ready when the config + safetensors are present.
    static func isReady() -> Bool {
        let d = dir
        return FileManager.default.fileExists(atPath: d.appendingPathComponent("config.json").path)
            && FileManager.default.fileExists(atPath: d.appendingPathComponent("model.safetensors").path)
    }
}

@MainActor
final class CloneModelManager: ObservableObject {
    static let shared = CloneModelManager()

    @Published var progress: Double? = nil       // 0...1 while downloading
    @Published var ready = false
    @Published var error: String?

    private var task: Task<Void, Never>?

    init() { ready = CloneModelInfo.isReady() }

    func refresh() { ready = CloneModelInfo.isReady() }

    func cancel() { task?.cancel(); task = nil; progress = nil }

    func download() {
        guard task == nil else { return }
        error = nil
        progress = 0
        task = Task {
            defer { task = nil }
            do {
                try FileManager.default.createDirectory(at: CloneModelInfo.dir, withIntermediateDirectories: true)
                let files = try await listFiles()
                let total = files.reduce(0) { $0 + $1.size }
                var done: Int64 = 0
                for f in files {
                    try Task.checkCancellation()
                    let dest = CloneModelInfo.dir.appendingPathComponent(f.name)
                    if FileManager.default.fileExists(atPath: dest.path),
                       (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) == f.size {
                        done += f.size
                        progress = total > 0 ? Double(done) / Double(total) : nil
                        continue
                    }
                    try await downloadFile(name: f.name, to: dest, sofar: done, total: total)
                    done += f.size
                }
                progress = nil
                ready = CloneModelInfo.isReady()
                if !ready { error = "Download finished but the model looks incomplete — try again." }
            } catch is CancellationError {
                progress = nil
            } catch {
                progress = nil
                self.error = "Model download failed: \(error.localizedDescription)"
            }
        }
    }

    private struct RemoteFile { let name: String; let size: Int64 }

    private func listFiles() async throws -> [RemoteFile] {
        let url = URL(string: "https://modelscope.cn/api/v1/models/\(CloneModelInfo.repo)/repo/files?Revision=master")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["Data"] as? [String: Any],
              let files = d["Files"] as? [[String: Any]] else {
            throw BuddyError("Couldn't read the model file list from ModelScope.")
        }
        return files.compactMap { f in
            guard let name = f["Name"] as? String, name.lowercased() != ".gitattributes",
                  (f["Type"] as? String) != "tree" else { return nil }
            let size = (f["Size"] as? NSNumber)?.int64Value ?? 0
            return RemoteFile(name: name, size: size)
        }
    }

    private func downloadFile(name: String, to dest: URL, sofar: Int64, total: Int64) async throws {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let url = URL(string: "https://modelscope.cn/models/\(CloneModelInfo.repo)/resolve/master/\(enc)")!
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue(Toolbox.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw BuddyError("HTTP \(http.statusCode) fetching \(name)")
        }
        let expected = resp.expectedContentLength
        let tmp = dest.appendingPathExtension("part")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var got: Int64 = 0
        var lastUI = Date()
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer); got += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastUI) > 0.3 {
                    lastUI = Date()
                    if total > 0 { progress = Double(sofar + got) / Double(total) }
                }
            }
            try Task.checkCancellation()
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try? handle.close()
        _ = expected
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

// ------------------------------------------------------------------ engine facade

/// Whether the cloned-voice engine was compiled into this build.
enum CloneTTSAvailability {
    static var isCompiledIn: Bool {
        #if canImport(Qwen3TTS)
        return true
        #else
        return false
        #endif
    }
}

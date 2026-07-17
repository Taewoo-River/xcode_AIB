import SwiftUI

// Download manager + picker UI for on-device GGUF models.
// Curated entries were verified against Hugging Face (HTTP 200 + sizes).

struct CuratedModel: Identifiable {
    let id: String        // file name on disk
    let title: String
    let url: String
    let sizeGB: Double
    let note: String
}

// Hosted on ModelScope: HuggingFace migrated to "Xet" storage in 2026, which
// 403s plain (unauthenticated) file downloads. ModelScope mirrors the same
// GGUFs over an ordinary CDN, so these download without an account. URLs and
// sizes were verified before shipping.
let curatedModels: [CuratedModel] = [
    CuratedModel(
        id: "Qwen3.5-0.8B-Q4_K_M.gguf",
        title: "Qwen3.5 0.8B",
        url: "https://modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/resolve/master/Qwen3.5-0.8B-Q4_K_M.gguf",
        sizeGB: 0.53,
        note: "Tiny & fastest — great first download to test the engine."
    ),
    CuratedModel(
        id: "Qwen3.5-2B-Q4_K_M.gguf",
        title: "Qwen3.5 2B",
        url: "https://modelscope.cn/models/unsloth/Qwen3.5-2B-GGUF/resolve/master/Qwen3.5-2B-Q4_K_M.gguf",
        sizeGB: 1.28,
        note: "Fast and capable — a good everyday pick."
    ),
    CuratedModel(
        id: "Qwen3.5-4B-Q4_K_M.gguf",
        title: "Qwen3.5 4B",
        url: "https://modelscope.cn/models/unsloth/Qwen3.5-4B-GGUF/resolve/master/Qwen3.5-4B-Q4_K_M.gguf",
        sizeGB: 2.74,
        note: "The same model your PC runs. Best quality/speed balance — recommended. Thinking model."
    ),
    CuratedModel(
        id: "gemma-4-E2B-it-Q4_K_M.gguf",
        title: "Gemma 4 E2B",
        url: "https://modelscope.cn/models/unsloth/gemma-4-E2B-it-GGUF/resolve/master/gemma-4-E2B-it-Q4_K_M.gguf",
        sizeGB: 3.11,
        note: "Google's newest efficient model."
    ),
    CuratedModel(
        id: "gemma-4-E4B-it-Q4_K_M.gguf",
        title: "Gemma 4 E4B",
        url: "https://modelscope.cn/models/unsloth/gemma-4-E4B-it-GGUF/resolve/master/gemma-4-E4B-it-Q4_K_M.gguf",
        sizeGB: 4.98,
        note: "⚠️ Big for an 8 GB iPad — may be slow or get killed by iPadOS. E2B is safer."
    ),
    // Older/smaller generation — light enough to answer quickly on the CPU,
    // which makes them ideal as the *background fallback* model.
    CuratedModel(
        id: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        title: "Qwen2.5 1.5B (light)",
        url: "https://modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf",
        sizeGB: 1.12,
        note: "Great background fallback — fast even on the CPU."
    ),
    CuratedModel(
        id: "gemma-2-2b-it-Q4_K_M.gguf",
        title: "Gemma 2 2B (light)",
        url: "https://modelscope.cn/models/bartowski/gemma-2-2b-it-GGUF/resolve/master/gemma-2-2b-it-Q4_K_M.gguf",
        sizeGB: 1.71,
        note: "Good background fallback."
    ),
    CuratedModel(
        id: "qwen2.5-3b-instruct-q4_k_m.gguf",
        title: "Qwen2.5 3B (light)",
        url: "https://modelscope.cn/models/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/master/qwen2.5-3b-instruct-q4_k_m.gguf",
        sizeGB: 2.10,
        note: "Solid previous-gen all-rounder; usable background fallback."
    ),
    // Vision projector: lets Gemma 4 models SEE images/your screen, fully
    // on-device. Select it under Brain → "Vision pack" after downloading.
    CuratedModel(
        id: "gemma-4-mmproj-F16.gguf",
        title: "Gemma 4 vision pack (mmproj)",
        url: "https://modelscope.cn/models/unsloth/gemma-4-E2B-it-GGUF/resolve/master/mmproj-F16.gguf",
        sizeGB: 0.99,
        note: "Pairs with the Gemma 4 models only. Enables on-device image & screen vision."
    )
]

/// The vision projector must never appear in the regular model pickers.
func isMmprojFile(_ name: String) -> Bool {
    name.lowercased().contains("mmproj")
}

// ------------------------------------------------------------------ manager
// Plain (non-actor) class: all UI-visible state is mutated on the main queue.

final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelManager()

    @Published var installed: [String] = []
    @Published var progress: [String: Double] = [:]   // file -> 0...1
    @Published var errors: [String: String] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session: URLSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: nil
    )

    override init() {
        super.init()
        try? FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)
        installed = Self.listInstalled()
    }

    static func listInstalled() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.models.path)) ?? []
        return files.filter { $0.lowercased().hasSuffix(".gguf") }.sorted()
    }

    static func fileURL(for name: String) -> URL {
        Paths.models.appendingPathComponent(name)
    }

    func refresh() {
        DispatchQueue.main.async { self.installed = Self.listInstalled() }
    }

    func sizeOnDisk(_ name: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Self.fileURL(for: name).path)
        let bytes = (attrs?[.size] as? NSNumber)?.doubleValue ?? 0
        return String(format: "%.2f GB", bytes / 1e9)
    }

    var freeSpaceGB: Double {
        let values = try? Paths.docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
    }

    // called from UI (main)
    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: Self.fileURL(for: name))
        #if canImport(llama)
        LlamaRuntime.shared.unloadAsync()
        #endif
        refresh()
    }

    // called from UI (main)
    func cancel(_ name: String) {
        tasks[name]?.cancel()
        tasks[name] = nil
        progress[name] = nil
    }

    // called from UI (main)
    func download(file: String, urlString: String) {
        guard tasks[file] == nil else { return }
        guard let url = URL(string: urlString) else {
            errors[file] = "Bad URL."
            return
        }
        errors[file] = nil
        progress[file] = 0
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue(Toolbox.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req)
        task.taskDescription = file
        tasks[file] = task
        task.resume()
    }

    // ------------------------------------------------------------- delegate (background queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let file = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let p = min(0.999, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        DispatchQueue.main.async {
            if self.progress[file] != nil { self.progress[file] = p }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let file = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let dest = Self.fileURL(for: file)
        var failure: String? = nil
        if status == 403 {
            failure = "Download blocked (403). Hugging Face links no longer download without an account — use a ModelScope link (modelscope.cn) instead."
        } else if status >= 400 {
            failure = "Download failed: HTTP \(status)"
        } else {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
            } catch {
                failure = "Couldn't save the file: \(error.localizedDescription)"
            }
        }
        DispatchQueue.main.async {
            self.tasks[file] = nil
            self.progress[file] = nil
            self.errors[file] = failure
            self.installed = Self.listInstalled()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let file = task.taskDescription else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        DispatchQueue.main.async {
            self.tasks[file] = nil
            self.progress[file] = nil
            if !cancelled {
                self.errors[file] = "Download failed: \(error.localizedDescription) — check Wi-Fi and free space, then try again."
            }
        }
    }
}

// ------------------------------------------------------------------ UI

struct ModelManagerView: View {
    @EnvironmentObject var engine: BuddyEngine
    @ObservedObject var manager = ModelManager.shared
    @State private var customURL = ""

    var body: some View {
        List {
            Section {
                ForEach(curatedModels) { m in
                    curatedRow(m)
                }
            } header: {
                Text("Recommended for this iPad (8 GB)")
            } footer: {
                Text("Models run fully on the iPad's GPU (Metal) — free, private, offline. Sizes are one-time downloads; keep the app open while downloading. Free space: \(String(format: "%.1f", manager.freeSpaceGB)) GB.\n(Qwen3.6's smallest release is a 14B model — too big for this iPad, so Qwen3.5 is the newest small Qwen.)")
            }

            if !manager.installed.isEmpty {
                Section("Downloaded") {
                    ForEach(manager.installed, id: \.self) { name in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(name).font(.callout)
                                Text(manager.sizeOnDisk(name)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isMmprojFile(name) {
                                // A vision projector, not a chat model — selected
                                // via Brain → "Vision pack 👁", not "Use".
                                Text("👁 vision").font(.caption).foregroundStyle(.secondary)
                            } else if engine.settings.ggufModel == name && engine.settings.mode == "gguf" {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Use") {
                                    engine.settings.ggufModel = name
                                    engine.settings.mode = "gguf"
                                }
                                .buttonStyle(.bordered)
                            }
                            Button(role: .destructive) {
                                if engine.settings.ggufModel == name { engine.settings.ggufModel = "" }
                                if engine.settings.ggufBackgroundModel == name { engine.settings.ggufBackgroundModel = "" }
                                if engine.settings.ggufMmproj == name { engine.settings.ggufMmproj = "" }
                                manager.delete(name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                TextField("Direct .gguf URL (e.g. from huggingface.co)", text: $customURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Download custom model") {
                    let name = URL(string: customURL)?.lastPathComponent ?? ""
                    guard name.lowercased().hasSuffix(".gguf") else { return }
                    manager.download(file: name, urlString: customURL)
                    customURL = ""
                }
                .disabled(!(URL(string: customURL)?.lastPathComponent.lowercased().hasSuffix(".gguf") ?? false))
                if let err = manager.errors.first(where: { !curatedModels.map(\.id).contains($0.key) })?.value {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
                ForEach(Array(manager.progress.keys.filter { k in !curatedModels.contains(where: { $0.id == k }) }), id: \.self) { k in
                    HStack {
                        Text(k).font(.caption)
                        Spacer()
                        ProgressView(value: manager.progress[k] ?? 0).frame(width: 90)
                        Button {
                            manager.cancel(k)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Custom")
            } footer: {
                Text("Paste any direct GGUF link (≤ ~3 GB, Q4 recommended). Use ModelScope — modelscope.cn/models → a *-GGUF repo → Files → long-press a Q4_K_M file's download button → Copy Link. (Hugging Face links no longer download without an account since their 2026 storage change.)")
            }
        }
        .navigationTitle("Local models")
        .onAppear { manager.refresh() }
    }

    @ViewBuilder
    private func curatedRow(_ m: CuratedModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.callout).bold()
                    Text(String(format: "%.2f GB — %@", m.sizeGB, m.note))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if manager.installed.contains(m.id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if let p = manager.progress[m.id] {
                    HStack(spacing: 8) {
                        ProgressView(value: p).frame(width: 90)
                        Text("\(Int(p * 100))%").font(.caption2).monospacedDigit()
                        Button {
                            manager.cancel(m.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Button("Get") {
                        manager.download(file: m.id, urlString: m.url)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let err = manager.errors[m.id] {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
    }
}

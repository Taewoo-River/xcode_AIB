import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var engine: BuddyEngine
    @EnvironmentObject var speaker: Speaker
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: String? = nil
    @State private var testing = false
    @ObservedObject private var modelManager = ModelManager.shared
    @State private var ollamaModels: [(name: String, caps: Set<String>)] = []
    @State private var vrmModels: [String] = []
    @State private var vrmStatus: String? = nil
    @State private var showVRMImporter = false
    @State private var confirmClear = false

    private let sttLocales = ["en-US", "en-GB", "en-AU", "en-IN", "ko-KR", "ja-JP", "zh-CN", "es-ES", "fr-FR", "de-DE"]

    var body: some View {
        NavigationStack {
            Form {
                brainSection
                personalitySection
                voiceOutSection
                voiceInSection
                proactiveSection
                avatarSection
                dataSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { vrmModels = VRMViewer.installedModels() }
        }
    }

    // ------------------------------------------------------------- brain

    private var brainSection: some View {
        Section {
            Picker("Brain", selection: $engine.settings.mode) {
                Text("Apple on-device (local, free)").tag("apple")
                Text("Local GGUF model (downloaded)").tag("gguf")
                Text("Google Gemini (cloud) 👁").tag("gemini")
                Text("OpenAI (cloud) 👁").tag("openai")
                Text("Anthropic Claude (cloud) 👁").tag("anthropic")
                Text("Ollama on your PC (Wi-Fi)").tag("ollama")
            }

            switch engine.settings.mode {
            case "apple":
                Text(AppleBrainFactory.statusLine())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case "gguf":
                if modelManager.installed.isEmpty {
                    Text("No models downloaded yet — tap Manage below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $engine.settings.ggufModel) {
                        ForEach(ggufChoices, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("Context length", selection: $engine.settings.ggufContext) {
                    Text("2k (fastest)").tag(2048)
                    Text("4k (default)").tag(4096)
                    Text("8k (more memory)").tag(8192)
                }
                NavigationLink("Manage / download models") {
                    ModelManagerView().environmentObject(engine)
                }
            case "gemini":
                SecureField("Gemini API key", text: $engine.settings.geminiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model", text: $engine.settings.geminiModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Link("Get a free key at aistudio.google.com/apikey", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.footnote)
            case "openai":
                SecureField("OpenAI API key", text: $engine.settings.openaiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model", text: $engine.settings.openaiModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case "anthropic":
                SecureField("Anthropic API key", text: $engine.settings.anthropicKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model", text: $engine.settings.anthropicModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case "ollama":
                TextField("PC address, e.g. http://192.168.0.23:11434", text: $engine.settings.ollamaBase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Model", text: $engine.settings.ollamaModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !ollamaModels.isEmpty {
                    Picker("Pulled models", selection: $engine.settings.ollamaModel) {
                        ForEach(allOllamaChoices, id: \.self) { name in
                            Text(ollamaLabel(name)).tag(name)
                        }
                    }
                }
                Button("Fetch model list from PC") {
                    Task {
                        ollamaModels = (try? await OllamaNativeProvider.listModels(base: engine.settings.ollamaBase)) ?? []
                        if ollamaModels.isEmpty { testResult = "Couldn't fetch models — check the address and that Ollama allows network access (see README)." }
                    }
                }
                Toggle("Model can see images (vision)", isOn: $engine.settings.ollamaVision)
                Toggle("Allow model thinking", isOn: $engine.settings.ollamaThink)
                Toggle("Keep model loaded in VRAM", isOn: $engine.settings.ollamaKeepAlive)
                Text("Tip: this field also accepts the Colab tunnel URL from the PC project (AI_Buddy/colab notebook) — a free big-GPU brain that runs Gemma 4 E4B or Qwen3.6-class models and works away from home.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }

            Button {
                testing = true
                testResult = nil
                Task {
                    testResult = await engine.testConnection()
                    testing = false
                }
            } label: {
                HStack {
                    Text("Test connection")
                    if testing { Spacer(); ProgressView() }
                }
            }
            if let r = testResult {
                Text(r).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Brain")
        } footer: {
            Text("👁 = can see images and your screen. Local GGUF and Apple on-device brains are text-only — to have the buddy look at your screen or photos, pick a 👁 brain (Gemini has a free tier). Local GGUF downloads open models (Qwen3.5, Gemma 4, …) and runs them on the iPad's GPU — free, private, offline. Ollama uses your PC's GPU over Wi-Fi (or a Colab tunnel from anywhere).")
        }
    }

    private var ggufChoices: [String] {
        var names = modelManager.installed
        if !engine.settings.ggufModel.isEmpty && !names.contains(engine.settings.ggufModel) {
            names.insert(engine.settings.ggufModel, at: 0)
        }
        return names
    }

    private var allOllamaChoices: [String] {
        var names = ollamaModels.map { $0.name }
        if !names.contains(engine.settings.ollamaModel) { names.insert(engine.settings.ollamaModel, at: 0) }
        return names
    }

    private func ollamaLabel(_ name: String) -> String {
        if let m = ollamaModels.first(where: { $0.name == name }), m.caps.contains("vision") {
            return "👁 " + name
        }
        return name
    }

    // ------------------------------------------------------------- personality

    private var personalitySection: some View {
        Section("Personality") {
            TextField("Buddy's name", text: $engine.settings.name)
            TextField("Your name (optional)", text: $engine.settings.userName)
            TextField("Extra personality notes (optional)", text: $engine.settings.extra, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    // ------------------------------------------------------------- voice output

    private var voiceOutSection: some View {
        Section {
            Toggle("Spoken replies", isOn: $engine.settings.speakEnabled)

            if CloneTTSAvailability.isCompiledIn {
                Picker("Voice engine", selection: $engine.settings.ttsEngine) {
                    Text("System voice").tag("system")
                    Text("Cloned voice").tag("clone")
                }
                if engine.settings.ttsEngine == "clone" {
                    NavigationLink("Cloned voices") {
                        VoiceCloneView().environmentObject(engine).environmentObject(speaker)
                    }
                }
            }

            if engine.settings.ttsEngine != "clone" {
                Picker("Default voice gender", selection: $engine.settings.voiceGender) {
                    Text("Male").tag("male")
                    Text("Female").tag("female")
                }
                Picker("Voice", selection: $engine.settings.voiceIdentifier) {
                    Text("Auto (best \(engine.settings.voiceGender) English voice)").tag("")
                    ForEach(Speaker.selectableVoices(), id: \.identifier) { v in
                        Text(voiceLabel(v)).tag(v.identifier)
                    }
                }
                .pickerStyle(.navigationLink)
                HStack {
                    Text("Speed")
                    Slider(value: $engine.settings.speechRate, in: 0.35...0.62)
                }
            }
            Button("Hear a sample") {
                speaker.speakSample("Hey! It's \(engine.settings.name). This is how I sound.")
            }
        } header: {
            Text("Voice output")
        } footer: {
            Text("For much nicer system voices: iPad Settings → Accessibility → Spoken Content → Voices → English, download an Enhanced or Premium voice, then pick it here. Cloned voices need the voice model downloaded and run on the GPU (foreground only — the system voice covers background replies).")
        }
    }

    private func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        var quality = ""
        if v.quality == .premium { quality = " ★★" }
        else if v.quality == .enhanced { quality = " ★" }
        return "\(v.name) (\(v.language))\(quality)"
    }

    // ------------------------------------------------------------- voice input

    private var voiceInSection: some View {
        Section {
            Picker("Language", selection: $engine.settings.sttLocale) {
                ForEach(sttLocales, id: \.self) { Text($0).tag($0) }
            }
            Toggle("On-device recognition (private)", isOn: $engine.settings.onDeviceRecognition)
            HStack {
                Text("End-of-speech pause")
                Slider(value: $engine.settings.silenceMs, in: 400...2000, step: 50)
                Text("\(Int(engine.settings.silenceMs)) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        } header: {
            Text("Voice input")
        } footer: {
            Text("How long you must pause before the buddy treats your sentence as finished. Shorter = snappier replies, but it may cut into mid-sentence pauses. Changes apply next time you toggle the mic.")
        }
    }

    // ------------------------------------------------------------- proactive

    private var proactiveSection: some View {
        Section {
            Toggle("Buddy starts conversations", isOn: $engine.settings.proactiveEnabled)
            Stepper(value: $engine.settings.idleMinutes, in: 1...120, step: 1) {
                Text("After \(Int(engine.settings.idleMinutes)) idle minute\(Int(engine.settings.idleMinutes) == 1 ? "" : "s")")
            }
            Stepper(value: $engine.settings.maxConsecutive, in: 1...5) {
                Text("Max \(engine.settings.maxConsecutive) in a row")
            }
            Toggle("Also nudge via notifications when the app is closed", isOn: $engine.settings.notifyWhenClosed)
        } header: {
            Text("Proactive chat")
        } footer: {
            Text("While the app is open it genuinely starts conversations. When it's closed, iPadOS doesn't let apps run, so it sends a notification nudge instead. The 🔔 button (or asking it to be quiet) snoozes both.")
        }
    }

    // ------------------------------------------------------------- avatar

    private var avatarSection: some View {
        Section {
            Picker("Style", selection: $engine.settings.avatarStyle) {
                Text("None").tag("none")
                Text("Jarvis HUD").tag("jarvis")
                Text("3D character (VRM)").tag("vrm")
            }
            if engine.settings.avatarStyle == "vrm" {
                if !vrmModels.isEmpty {
                    Picker("Character", selection: $engine.settings.vrmModel) {
                        ForEach(vrmChoices, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button("Download 4 sample characters (~60 MB)") {
                    Task {
                        vrmStatus = "Starting…"
                        let result = await VRMViewer.downloadSamples { vrmStatus = $0 }
                        vrmStatus = result
                        vrmModels = VRMViewer.installedModels()
                        if engine.settings.vrmModel.isEmpty, let first = vrmModels.first {
                            engine.settings.vrmModel = first
                        }
                    }
                }
                Button("Import a .vrm file…") { showVRMImporter = true }
                if let s = vrmStatus {
                    Text(s).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Avatar")
        } footer: {
            Text(engine.settings.avatarStyle == "vrm"
                 ? "Grab more free characters at hub.vroid.com — download the .vrm and import it here. 3D avatars need internet on first load for the three.js libraries."
                 : "The Jarvis HUD works offline with zero setup.")
        }
        .fileImporter(isPresented: $showVRMImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let name = try VRMViewer.importModel(from: url)
                    vrmModels = VRMViewer.installedModels()
                    engine.settings.vrmModel = name
                    vrmStatus = "Imported \(name)."
                } catch {
                    vrmStatus = "Import failed: \(error.localizedDescription)"
                }
            case .failure(let error):
                vrmStatus = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private var vrmChoices: [String] {
        var names = vrmModels
        if !engine.settings.vrmModel.isEmpty && !names.contains(engine.settings.vrmModel) {
            names.insert(engine.settings.vrmModel, at: 0)
        }
        return names
    }

    // ------------------------------------------------------------- data

    private var dataSection: some View {
        Section {
            Toggle("Allow looking at my screenshots", isOn: $engine.settings.screenEnabled)
            Stepper(value: $engine.settings.historyLimit, in: 10...100, step: 10) {
                Text("Context: last \(engine.settings.historyLimit) messages")
            }
            Button("Clear chat history", role: .destructive) { confirmClear = true }
                .confirmationDialog("Delete the whole conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Delete everything", role: .destructive) { engine.clearHistory() }
                }
        } header: {
            Text("Data")
        } footer: {
            Text("Chat history and settings (including API keys) are stored only in this app's private documents folder on the iPad.")
        }
    }
}

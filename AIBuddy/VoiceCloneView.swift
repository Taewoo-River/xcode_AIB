import SwiftUI
import UniformTypeIdentifiers

struct VoiceCloneView: View {
    @EnvironmentObject var engine: BuddyEngine
    @ObservedObject var store = VoiceClipStore.shared
    @ObservedObject var model = CloneModelManager.shared
    @EnvironmentObject var speaker: Speaker

    @State private var showImporter = false
    @State private var editing: VoiceClip?
    @State private var editText = ""

    var body: some View {
        List {
            // ---- voice model ----
            Section {
                if model.ready {
                    Label("Voice model ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let p = model.progress {
                    HStack {
                        ProgressView(value: p)
                        Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                        Button("Cancel") { model.cancel() }.buttonStyle(.borderless)
                    }
                } else {
                    Button("Download voice model (~1.8 GB, one time)") { model.download() }
                }
                if let e = model.error {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Voice model")
            } footer: {
                Text("Qwen3-TTS runs the cloning on the iPad's GPU. It's downloaded once from ModelScope.")
            }

            // ---- clips ----
            Section {
                if store.clips.isEmpty {
                    Text("No voices yet. Import a clean 5–15 s audio clip of a voice below.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.clips) { clip in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: engine.settings.cloneVoiceFile == clip.file ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(.cyan)
                                .onTapGesture { engine.settings.cloneVoiceFile = clip.file }
                            Text(clip.name)
                            Spacer()
                            Button {
                                editing = clip; editText = clip.referenceText
                            } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) {
                                if engine.settings.cloneVoiceFile == clip.file { engine.settings.cloneVoiceFile = "" }
                                store.delete(clip)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        Text(clip.referenceText.isEmpty ? "⚠️ no transcript — tap ✏️ to add what the clip says" : "“\(clip.referenceText)”")
                            .font(.caption2)
                            .foregroundStyle(clip.referenceText.isEmpty ? .orange : .secondary)
                            .lineLimit(2)
                    }
                }
                if store.importing {
                    HStack { ProgressView(); Text("Importing & transcribing…").font(.footnote) }
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import a voice clip", systemImage: "waveform.badge.plus")
                }
                if let e = store.importError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Voices")
            } footer: {
                Text("Use a clean recording (no music/noise) of one speaker. The app auto-transcribes it; fix the transcript with ✏️ if it's off — accuracy matters for the clone. Only clone voices you have permission to use.")
            }

            if model.ready && !engine.settings.cloneVoiceFile.isEmpty {
                Section {
                    Button("Hear the cloned voice") {
                        speaker.speakSample("Hi! This is my cloned voice. What do you think?")
                    }
                }
            }
        }
        .navigationTitle("Cloned voices")
        .onAppear { model.refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.importClip(from: url, name: url.deletingPathExtension().lastPathComponent)
            }
        }
        .sheet(item: $editing) { clip in
            NavigationStack {
                Form {
                    Section("What the clip says (transcript)") {
                        TextField("e.g. Hello, this is my voice.", text: $editText, axis: .vertical)
                            .lineLimit(3...8)
                    }
                }
                .navigationTitle(clip.name)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { store.updateText(clip, text: editText); editing = nil }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editing = nil }
                    }
                }
            }
        }
    }
}

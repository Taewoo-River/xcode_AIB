import SwiftUI
import PhotosUI
import Photos

struct ChatView: View {
    @EnvironmentObject var engine: BuddyEngine
    @EnvironmentObject var speaker: Speaker
    @EnvironmentObject var voice: VoiceInput
    @ObservedObject var screenWatch = ScreenWatch.shared

    @State private var input = ""
    @State private var showSettings = false
    @State private var showAvatar = true
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var attachedImages: [String] = []
    @FocusState private var inputFocused: Bool

    private var avatarState: String {
        if speaker.isSpeaking { return "speaking" }
        if engine.isGenerating { return "thinking" }
        if voice.armed { return "listening" }
        return "idle"
    }

    private var avatarLevel: Double {
        if speaker.isSpeaking { return max(0.4, speaker.pulse) }
        if voice.armed { return voice.level }
        return 0
    }

    private var isQuiet: Bool {
        if let q = engine.quietUntil { return Date() < q }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showAvatar && engine.settings.avatarStyle != "none" {
                avatarPanel
            }
            messageList
            if voice.armed || voice.authProblem != nil {
                voiceBar
            }
            inputBar
        }
        .background(Color(red: 0.05, green: 0.07, blue: 0.1).ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(engine)
                .environmentObject(speaker)
        }
    }

    // ------------------------------------------------------------- header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.circle.fill")
                .font(.title2)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(engine.settings.name)
                    .font(.headline)
                Text(engine.settings.brainLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ZStack(alignment: .topTrailing) {
                BroadcastPickerButton()
                    .frame(width: 34, height: 34)
                if screenWatch.isWatching {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 9, height: 9)
                        .offset(x: 2, y: -2)
                }
            }
            .help("Start/stop live screen watching")
            Button {
                withAnimation { showAvatar.toggle() }
            } label: {
                Image(systemName: showAvatar ? "circle.hexagongrid.fill" : "circle.hexagongrid")
            }
            Button {
                if isQuiet {
                    engine.applyQuiet(minutes: 0)
                } else {
                    engine.applyQuiet(minutes: 60)
                }
            } label: {
                Image(systemName: isQuiet ? "bell.slash.fill" : "bell.fill")
                    .foregroundStyle(isQuiet ? .orange : .cyan)
            }
            Button {
                engine.settings.speakEnabled.toggle()
                if !engine.settings.speakEnabled { speaker.stopAll() }
            } label: {
                Image(systemName: engine.settings.speakEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
            }
        }
        .font(.title3)
        .tint(.cyan)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.25))
    }

    // ------------------------------------------------------------- avatar

    private var avatarPanel: some View {
        ZStack {
            if engine.settings.avatarStyle == "vrm" {
                if engine.settings.vrmModel.isEmpty {
                    Text("No VRM character selected — pick or download one in settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    VRMAvatarView(
                        modelFile: engine.settings.vrmModel,
                        state: avatarState,
                        level: avatarLevel
                    )
                    .id(engine.settings.vrmModel)
                }
            } else {
                JarvisView(state: avatarState, level: avatarLevel)
            }
        }
        .frame(height: 250)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.2))
    }

    // ------------------------------------------------------------- messages

    private var visibleMessages: [ChatMessage] {
        engine.messages.filter { !$0.hidden }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if visibleMessages.isEmpty && engine.currentReply.isEmpty {
                        Text("Say hi — type below or tap the mic. ⚙️ picks the brain (Apple on-device, Gemini, OpenAI, Claude, or Ollama on your PC).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                            .padding(.horizontal, 30)
                    }
                    ForEach(visibleMessages) { msg in
                        bubble(msg)
                    }
                    if engine.isGenerating || !engine.currentReply.isEmpty {
                        streamingBubble
                    }
                    if let err = engine.errorText {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(10)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: engine.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: engine.currentReply) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func markdownText(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.role == "user" { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(msg.images.enumerated()), id: \.offset) { _, b64 in
                    if let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                if !msg.content.isEmpty {
                    markdownText(msg.content)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                msg.role == "user" ? Color.cyan.opacity(0.22) : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .foregroundStyle(.primary)
            if msg.role != "user" { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 14)
    }

    private var streamingBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if engine.currentReply.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(engine.toolStatus ?? "thinking…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    markdownText(engine.currentReply)
                        .font(.body)
                    if let status = engine.toolStatus {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 14)
    }

    // ------------------------------------------------------------- voice status

    private var voiceBar: some View {
        HStack(spacing: 10) {
            if let problem = voice.authProblem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(problem).font(.footnote).foregroundStyle(.yellow)
            } else {
                Image(systemName: "waveform")
                    .foregroundStyle(.green)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(voice.preview.isEmpty ? "listening — just start talking…" : voice.preview)
                    .font(.footnote)
                    .foregroundStyle(voice.preview.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.black.opacity(0.3))
    }

    // ------------------------------------------------------------- input bar

    private var inputBar: some View {
        VStack(spacing: 6) {
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachedImages.enumerated()), id: \.offset) { idx, b64 in
                            ZStack(alignment: .topTrailing) {
                                if let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button {
                                    attachedImages.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                if !engine.settings.visionCapable {
                    Text("⚠️ The current brain can't see images — switch to Gemini, OpenAI, Claude, or a vision Ollama model in ⚙️.")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 16)
                }
            }
            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 3, matching: .images) {
                    Image(systemName: "photo")
                        .font(.title3)
                }
                .onChange(of: pickerItems) { _, items in
                    guard !items.isEmpty else { return }
                    Task {
                        for item in items {
                            if let data = try? await item.loadTransferable(type: Data.self),
                               let img = UIImage(data: data),
                               let b64 = Self.jpegBase64(img) {
                                attachedImages.append(b64)
                            }
                        }
                        pickerItems = []
                    }
                }

                Button {
                    attachLatestScreenshot()
                } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.title3)
                }
                .help("Attach your most recent screenshot")

                TextField("Message \(engine.settings.name)…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                    .onChange(of: input) { old, new in
                        // typing barges in, like the PC version
                        if new.count > old.count && (engine.isGenerating || speaker.isSpeaking) {
                            engine.interrupt()
                        }
                    }
                    .onSubmit { sendNow() }

                Button {
                    voice.setArmed(!voice.armed)
                } label: {
                    Image(systemName: voice.armed ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundStyle(voice.armed ? .red : .cyan)
                        .padding(8)
                        .background(
                            Circle().fill(voice.armed ? Color.red.opacity(0.18) : Color.clear)
                        )
                }

                Button(action: sendNow) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedImages.isEmpty)
            }
            .tint(.cyan)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.black.opacity(0.25))
    }

    private func sendNow() {
        let text = input
        let images = attachedImages
        input = ""
        attachedImages = []
        engine.send(text: text, images: images)
    }

    /// The iPad's stand-in for the PC version's screen-watching: grab the
    /// newest screenshot from Photos (take one with Top button + Volume Up).
    private func attachLatestScreenshot() {
        Task {
            switch await ScreenPeek.latestScreenshot(maxAgeSeconds: 60 * 60 * 24) {
            case .found(let b64, _):
                attachedImages.append(b64)
            case .noPermission:
                engine.errorText = "Photos permission needed — allow it in iPad Settings → Privacy & Security → Photos → AI Buddy."
            default:
                engine.errorText = "No screenshot found — take one first (Top button + Volume Up together)."
            }
        }
    }

    static func jpegBase64(_ img: UIImage, maxDim: CGFloat = 1400) -> String? {
        let biggest = max(img.size.width, img.size.height)
        let scale = biggest > maxDim ? maxDim / biggest : 1
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.7)?.base64EncodedString()
    }
}

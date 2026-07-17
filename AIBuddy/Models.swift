import Foundation

// ------------------------------------------------------------------ errors

struct BuddyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// ------------------------------------------------------------------ chat history

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: String            // "user" | "assistant"
    var content: String
    var hidden: Bool = false    // [SYSTEM ...] notes the user never sees
    var images: [String] = []   // base64 JPEG, stripped when saved to disk

    enum CodingKeys: String, CodingKey { case id, role, content, hidden, images }

    init(role: String, content: String, hidden: Bool = false, images: [String] = []) {
        self.role = role
        self.content = content
        self.hidden = hidden
        self.images = images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        role = (try? c.decode(String.self, forKey: .role)) ?? "user"
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
        images = (try? c.decode([String].self, forKey: .images)) ?? []
    }
}

// ------------------------------------------------------------------ provider-neutral LLM types
// Mirrors llm.py's internal message format.

struct LLMMessage {
    var role: String            // system | user | assistant | tool
    var content: String
    var images: [String] = []   // base64 JPEG
    var toolCalls: [ToolCallReq] = []
    var toolCallId: String = ""
    var toolName: String = ""
}

struct ToolCallReq {
    var id: String
    var name: String
    var arguments: [String: Any]
}

enum LLMEvent {
    case text(String)
    case toolCalls([ToolCallReq])
}

struct ToolSpec {
    var name: String
    var description: String
    var parameters: [String: Any]
}

protocol LLMProvider {
    var vision: Bool { get }
    /// True when the provider runs tools itself (Apple FoundationModels).
    var handlesToolsInternally: Bool { get }
    func stream(messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error>
}

// ------------------------------------------------------------------ settings
// Mirrors config.yaml.

struct BuddySettings: Codable {
    // brain
    var mode: String = "apple"  // apple | gemini | openai | anthropic | ollama
    var geminiKey: String = ""
    var geminiModel: String = "gemini-2.5-flash"
    var openaiKey: String = ""
    var openaiModel: String = "gpt-4o-mini"
    var anthropicKey: String = ""
    var anthropicModel: String = "claude-opus-4-8"
    var ollamaBase: String = "http://192.168.0.2:11434"
    var ollamaModel: String = "qwen3.5:4b"
    var ollamaVision: Bool = true
    var ollamaThink: Bool = true
    var ollamaKeepAlive: Bool = true
    var ggufModel: String = ""          // file in Documents/models
    var ggufContext: Int = 4096
    var ggufBackgroundModel: String = "" // smaller model swapped in for background (CPU) replies; "" = same model
    var ggufMmproj: String = ""          // vision projector (mmproj) file enabling image input; "" = text-only

    // personality
    var name: String = "Nova"
    var userName: String = ""
    var extra: String = ""

    // voice output
    var speakEnabled: Bool = true
    var voiceIdentifier: String = ""      // empty = auto-pick by gender
    var voiceGender: String = "male"      // male | female
    var speechRate: Double = 0.5          // AVSpeechUtteranceDefaultSpeechRate is 0.5
    var ttsEngine: String = "system"      // system | clone (Qwen3-TTS)
    var cloneVoiceFile: String = ""       // selected voice clip in Documents/voices/

    // voice input
    var sttLocale: String = "en-US"
    var onDeviceRecognition: Bool = true
    var silenceMs: Double = 950           // end-of-speech pause

    // proactive
    var proactiveEnabled: Bool = true
    var idleMinutes: Double = 5
    var maxConsecutive: Int = 2
    var notifyWhenClosed: Bool = true

    // screen (via recent screenshots)
    var screenEnabled: Bool = true

    // avatar
    var avatarStyle: String = "jarvis"    // none | jarvis | vrm
    var vrmModel: String = ""

    var historyLimit: Int = 30

    init() {}

    // Tolerant decoding so adding fields never wipes existing settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys, _ d: String) -> String { (try? c.decode(String.self, forKey: k)) ?? d }
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decode(Bool.self, forKey: k)) ?? d }
        func dbl(_ k: CodingKeys, _ d: Double) -> Double { (try? c.decode(Double.self, forKey: k)) ?? d }
        func i(_ k: CodingKeys, _ d: Int) -> Int { (try? c.decode(Int.self, forKey: k)) ?? d }
        mode = s(.mode, "apple")
        geminiKey = s(.geminiKey, ""); geminiModel = s(.geminiModel, "gemini-2.5-flash")
        openaiKey = s(.openaiKey, ""); openaiModel = s(.openaiModel, "gpt-4o-mini")
        anthropicKey = s(.anthropicKey, ""); anthropicModel = s(.anthropicModel, "claude-opus-4-8")
        ollamaBase = s(.ollamaBase, "http://192.168.0.2:11434")
        ollamaModel = s(.ollamaModel, "qwen3.5:4b")
        ollamaVision = b(.ollamaVision, true)
        ollamaThink = b(.ollamaThink, true)
        ollamaKeepAlive = b(.ollamaKeepAlive, true)
        screenEnabled = b(.screenEnabled, true)
        ggufModel = s(.ggufModel, "")
        ggufContext = i(.ggufContext, 4096)
        ggufBackgroundModel = s(.ggufBackgroundModel, "")
        ggufMmproj = s(.ggufMmproj, "")
        name = s(.name, "Nova"); userName = s(.userName, ""); extra = s(.extra, "")
        speakEnabled = b(.speakEnabled, true)
        voiceIdentifier = s(.voiceIdentifier, ""); voiceGender = s(.voiceGender, "male")
        speechRate = dbl(.speechRate, 0.5)
        ttsEngine = s(.ttsEngine, "system")
        cloneVoiceFile = s(.cloneVoiceFile, "")
        sttLocale = s(.sttLocale, "en-US")
        onDeviceRecognition = b(.onDeviceRecognition, true)
        silenceMs = dbl(.silenceMs, 950)
        proactiveEnabled = b(.proactiveEnabled, true)
        idleMinutes = dbl(.idleMinutes, 5)
        maxConsecutive = i(.maxConsecutive, 2)
        notifyWhenClosed = b(.notifyWhenClosed, true)
        avatarStyle = s(.avatarStyle, "jarvis")
        vrmModel = s(.vrmModel, "")
        historyLimit = i(.historyLimit, 30)
    }

    var brainLabel: String {
        switch mode {
        case "apple": return "Apple on-device"
        case "gemini": return "Gemini · \(geminiModel)"
        case "openai": return "OpenAI · \(openaiModel)"
        case "anthropic": return "Claude · \(anthropicModel)"
        case "ollama": return "Ollama · \(ollamaModel)"
        case "gguf": return "Local · \(ggufModel.isEmpty ? "no model" : ggufModel.replacingOccurrences(of: ".gguf", with: ""))"
        default: return mode
        }
    }

    /// Whether the currently selected brain can see attached images.
    var visionCapable: Bool {
        switch mode {
        case "gemini", "openai", "anthropic": return true
        case "ollama": return ollamaVision
        case "gguf": return !ggufMmproj.isEmpty   // vision pack (mmproj) installed
        default: return false   // apple on-device is text-only
        }
    }
}

// ------------------------------------------------------------------ JSON helpers (JSONSerialization plumbing)

func jdict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
func jarr(_ v: Any?) -> [[String: Any]] { (v as? [[String: Any]]) ?? [] }
func jstr(_ v: Any?) -> String { v as? String ?? "" }

// ------------------------------------------------------------------ file locations

enum Paths {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let history = docs.appendingPathComponent("history.json")
    static let settings = docs.appendingPathComponent("settings.json")
    static let avatars = docs.appendingPathComponent("avatars", isDirectory: true)
    static let models = docs.appendingPathComponent("models", isDirectory: true)
    static let voices = docs.appendingPathComponent("voices", isDirectory: true)
}

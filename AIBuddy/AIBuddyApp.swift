import SwiftUI

@main
struct AIBuddyApp: App {
    @StateObject private var engine = BuddyEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(engine)
                .environmentObject(engine.speaker)
                .environmentObject(engine.voice)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                engine.enteredForeground()
            case .background:
                engine.enteredBackground()
            default:
                break
            }
        }
    }
}

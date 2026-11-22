import AVFoundation
import SwiftUI

@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable {
        case flow
        case history
        case dictionary
        case settings
    }

    var selectedTab: Tab = .flow
    var showFallbackDictation = false
    var shouldPromptMicPermission = false

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == AppGroup.urlScheme else { return }
        switch url.host {
        case "settings":
            selectedTab = .settings
        case "history":
            selectedTab = .history
        case "dictionary":
            selectedTab = .dictionary
        case "setup-mic":
            selectedTab = .flow
            shouldPromptMicPermission = true
        case "setup-keyboard":
            selectedTab = .flow
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsURL)
            }
        case "dictate":
            selectedTab = .flow
            showFallbackDictation = true
        default:
            selectedTab = .flow
        }
    }
}

@main
struct LocalWhisperApp: App {
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            ContentView(router: router)
                .onOpenURL { url in
                    router.handleIncomingURL(url)
                }
        }
    }
}

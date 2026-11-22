import SwiftUI
import UIKit

@MainActor enum AppRuntime {
    static let result = Result { try AppState() }
    static var store: AppState? { try? result.get() }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = AppRuntime.store // Register background handlers before launch completes.
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard let store = AppRuntime.store, let download = store.allDownloads.first(where: { $0.sessionID == identifier }) else { completionHandler(); return }
        download.backgroundCompletion = completionHandler
    }
}

@main
struct IslandApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            Group {
                switch AppRuntime.result {
                case .success(let store): RootView(store: store)
                case .failure(let error): ContentUnavailableView("Loocal couldn’t start", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
                }
            }
        }
    }
}

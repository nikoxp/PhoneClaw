import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundDownloadSession.shared.setBackgroundCompletionHandler(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct PhoneClawApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        PCLog.suppressRuntimeNoise()
        #if DEBUG
        AudioBypassTest.runIfRequested()
        #endif
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

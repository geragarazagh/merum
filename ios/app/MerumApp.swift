// Merum for iPhone: the entry, the window and the one library.
//
// UIKit owns the window (a UIHostingController inside it) for one reason: the window's undo manager. Shake to undo
// with no text view active (the list) asks the window, and it must reach the core's History, not a manager of its own.
import SwiftUI
import UIKit

/// The process's one library and what hangs off it.
@MainActor final class Merum {
    static let shared = Merum()
    let library: Library
    let model: Model
    #if MERUM_ICLOUD
    private(set) var sync: Sync?
    private(set) var settingsSync: SettingsSync?
    #endif

    private init() {
        library = Library(store: Store())
        model = Model(library: library)
        // iCloud only in a build that carries the CloudKit entitlement: without it CKContainer stops the process.
        #if MERUM_ICLOUD
        let s = Sync(library: library, database: CloudKitDatabase())
        s.start()
        sync = s
        let ss = SettingsSync(library: library)
        ss.start()
        settingsSync = ss
        #endif
    }
}

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = Merum.shared
        #if DEBUG && targetEnvironment(simulator)
        SimulatorModes.runIfAsked()
        Probe.runIfAsked()
        #endif
        #if MERUM_ICLOUD
        application.registerForRemoteNotifications()
        #if DEBUG
        CloudCheck.runIfAsked()
        SyncProbe.runIfAsked()
        #endif   // the zone's silent pushes; no alert, badge or sound is asked for
        #endif
        return true
    }

    #if MERUM_ICLOUD
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        Merum.shared.sync?.handlePush(userInfo) == true ? .newData : .noData
    }
    #endif
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let app = Merum.shared
        let w = HistoryWindow(windowScene: ws)
        w.proxy.history = app.library.history.undoManager
        w.rootViewController = UIHostingController(rootView: RootView().environment(app.model))
        w.makeKeyAndVisible()
        window = w
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        Merum.shared.library.flush()
    }

    // In front the core fetches at once and then every 15 s (silent pushes are throttled); behind, pushes and the
    // next time in front bring changes.
    func sceneDidBecomeActive(_ scene: UIScene) {
        #if MERUM_ICLOUD
        Merum.shared.sync?.setForeground(true)
        #endif
    }

    func sceneWillResignActive(_ scene: UIScene) {
        #if MERUM_ICLOUD
        Merum.shared.sync?.setForeground(false)
        #endif
    }
}

/// The window's undo manager is the History's, behind the same forwarding manager the text views use: whatever asks
/// the window (shake on the list, a text field in an alert) undoes the one history and registers nothing of its own.
final class HistoryWindow: UIWindow {
    let proxy = ForwardingUndoManager()
    override var undoManager: UndoManager? { proxy }
}

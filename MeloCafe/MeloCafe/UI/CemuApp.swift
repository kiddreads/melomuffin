//
//  CemuApp.swift
//  melomuffin
//
//  Adapted from cemu-ios-muffin's src/ios/App/CemuApp.swift AND MeloCafe's own
//  (removed) UI/MeloCafeApp.swift.
//
//  MELOMUFFIN ADAPTATION NOTE:
//  Muffin's own app entry is a plain SwiftUI `@main struct CemuApp: App { ... }` -
//  its own bridge (CemuBridge.mm) installs an early crash handler as a high-priority
//  C++ static constructor, so Muffin's Swift-side init() has nothing to set up
//  beyond a couple of UserDefaults-backed renderer flags that only make sense
//  against cemu_bridge_set_geometry_shader_emulation_enabled/
//  cemu_bridge_set_vsync_enabled - neither of which exists on this bridge.
//
//  MeloCafe's own real requirements are heavier, and a plain SwiftUI `App`/
//  `WindowGroup` cannot provide them - this is why MeloCafe's OWN entry point
//  (the file this replaces) was a UIKit AppDelegate + UIWindowSceneDelegate, not a
//  SwiftUI App, and that shape has to stay:
//    - CemuManager.initialize() (Core/CemuManager.swift) must run once, early, from
//      application(didFinishLaunching:).
//    - MeloCafe needs a concrete UIWindow (CemuUIKit_SetMainWindow) so its own
//      WindowSystem::ShowErrorDialog can present on it - a SwiftUI WindowGroup does
//      not hand one out.
//    - The JIT trap handler + DUAL_MAPPED_JIT/HAS_TXM environment setup has to run
//      before any title boots, and CemuConfigWrapper's multicore-interpreter
//      fallback (checkAppEntitlement("get-task-allow")) has to run before
//      CemuManager.initialize() reads it.
//
//  So this file keeps MeloCafe's own class names (`MainSceneDelegate`) - Info.plist's
//  UIApplicationSceneManifest already names it - and mounts Muffin's SwiftUI
//  ContentView inside MeloCafe's real UIWindow, instead of MeloCafe's own
//  ContentView. The iOS 27 external-display accessory scene MeloCafe's own version
//  registered is dropped: Muffin's DisplayRouter (ported alongside this file) does
//  its own external-display handling directly off UIScreen/UIWindow, and
//  Info.plist's External Display scene role was removed to match - see
//  DisplayRouter.swift.
//
import UIKit
import SwiftUI
import GameController

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "0", 1)
        setenv("MVK_CONFIG_DEBUG", "0", 1)
        setenv("MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE", "128", 1)
        CemuManager.initialize()
        return true
    }
}

final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let gameManager = GameManager()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window

        CemuUIKit_SetMainWindow(window)

        installJITTrapHandler()
        configureJITEnvironment()
        if !checkAppEntitlement("get-task-allow") {
            CemuConfigWrapper.shared().cpuMode = .multicoreInterpreter
        }

        window.rootViewController = UIHostingController(
            rootView: ContentView().environmentObject(gameManager)
        )
        window.makeKeyAndVisible()

        DisplayRouter.shared.startObserving()
    }

    private func configureJITEnvironment() {
        if #available(iOS 19.0, *) {
            setenv("DUAL_MAPPED_JIT", "1", 1)
            setenv("HAS_TXM", !ProcessInfo.processInfo.isiOSAppOnMac && ProcessInfo.processInfo.hasTXM ? "1" : "0", 1)
        } else {
            setenv("HAS_TXM", "0", 1)
        }
    }
}

//
//  CrashCamSceneDelegate.swift
//  CrashCam
//
//  Drop-in bridge for SwiftUI-lifecycle apps (no SceneDelegate of their own):
//  touch recording needs `TrackingWindow` installed as the app's window, which
//  UIKit-lifecycle apps do in their own SceneDelegate. SwiftUI apps instead
//  declare an app-delegate adaptor subclassing `CrashCamAppDelegate`:
//
//      class AppDelegate: CrashCamAppDelegate {
//          func application(_ application: UIApplication,
//                           didFinishLaunchingWithOptions launchOptions:
//                               [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
//              CrashCam.shared.bootstrap(uploadEndpoint: ..., uploadToken: ...)
//              return true
//          }
//      }
//
//      @main struct MyApp: App {
//          @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
//          var body: some Scene { WindowGroup { ContentView() } }
//      }
//
//  The adaptor routes every window scene through `CrashCamSceneDelegate`,
//  which creates a `TrackingWindow` and leaves it for SwiftUI to populate
//  with the `WindowGroup` content (SwiftUI adopts a window the scene
//  delegate has already created instead of making its own).
//

import UIKit

/// Scene delegate that installs `TrackingWindow` and lets SwiftUI host its
/// content inside it. Subclass if the app needs its own scene handling.
open class CrashCamSceneDelegate: NSObject, UIWindowSceneDelegate {

    public var window: UIWindow?

    open func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = TrackingWindow(windowScene: windowScene)
    }
}

/// App delegate base whose only job is announcing `CrashCamSceneDelegate` for
/// application window scenes. Subclass it, call `CrashCam.shared.bootstrap`
/// from `application(_:didFinishLaunchingWithOptions:)`, and attach the
/// subclass with `@UIApplicationDelegateAdaptor`.
open class CrashCamAppDelegate: NSObject, UIApplicationDelegate {

    open func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = CrashCamSceneDelegate.self
        }
        return configuration
    }
}

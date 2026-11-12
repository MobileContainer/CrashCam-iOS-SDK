//
//  CrashCamSceneDelegate.swift
//  CrashCam
//
//  Not needed since SDK 2.1.0: `CrashCam.bootstrap()` records touches through
//  an application-level hook (see `TouchRecorder`), so a SwiftUI-lifecycle app
//  only calls `bootstrap()` from its `App`'s `init()`. These classes are kept
//  so apps integrated earlier keep compiling and working.
//
//  What they do: route every window scene through `CrashCamSceneDelegate`,
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

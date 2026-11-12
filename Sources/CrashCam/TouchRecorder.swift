//
//  TouchRecorder.swift
//  CrashCam
//
//  Records every touch of the app, with no window or scene-delegate setup:
//  `UIApplication.sendEvent(_:)` is swizzled once at `CrashCam.bootstrap`
//  (public-API `method_exchangeImplementations`, the same technique
//  `ScreenTracker` uses for `viewDidAppear`). Every touch event of the process
//  passes through that method before UIKit hands it to a window, so UIKit,
//  storyboard and SwiftUI-lifecycle apps are all covered by `bootstrap()`
//  alone.
//
//  Recording happens BEFORE the event is forwarded. The crash this tool exists
//  to capture is usually raised synchronously by a handler of this very event
//  (a button action or gesture callback runs inside the dispatch), so
//  recording after forwarding loses the final — fatal — touch.
//
//  Which windows count. Only the app's own windows are recorded: a plain
//  `UIWindow`, or a window class that ships inside the app bundle (including
//  `TrackingWindow`). UIKit's private window classes — the keyboard, text
//  effects, system overlays — are never recorded. That is a privacy rule, not
//  an optimisation: where a keyboard runs inside the process, the positions of
//  key taps would spell out what was typed, and CrashCam records text length
//  only. CrashCam's own debug windows (replay button, replay pointer) are
//  skipped too.
//
//  Coordinates stay what recordings have always held: points in the app's
//  main window. A touch in another of the app's windows (an overlay, a toast)
//  is converted into the main window of the same scene.
//
//  `TrackingWindow` used to be the recorder. It still works: when this hook is
//  active it records nothing itself (no double rows), and when the hook is
//  switched off (`CrashCam.shared.automaticTouchRecording = false`) or
//  `bootstrap()` was never called, it records its own touches as before.
//

import ObjectiveC
import UIKit

@MainActor
enum TouchRecorder {

    /// Recording from the application-level hook. On by default; when false
    /// only a `TrackingWindow` records.
    static var isAutomatic = true

    private(set) static var hookInstalled = false

    /// True when the application hook is the one recording, i.e. a
    /// `TrackingWindow` must stay silent.
    static var applicationHookRecords: Bool { hookInstalled && isAutomatic }

    /// Swizzles `UIApplication.sendEvent(_:)`. Idempotent; called from
    /// `CrashCam.bootstrap`.
    static func installApplicationHook() {
        guard !hookInstalled,
              let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
              let hook = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.crashCam_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, hook)
        hookInstalled = true
    }

    // MARK: - Recording

    /// Writes one row per began / moved / ended touch of `event`. `only`
    /// restricts it to the touches of one window (the `TrackingWindow` path).
    /// A cancelled touch is written as ended (the format has no cancel
    /// phase), so no finger is left down in the recording.
    static func record(_ event: UIEvent, only: UIWindow? = nil) {
        guard event.type == .touches, let touches = event.allTouches, !touches.isEmpty else { return }
        let tracker = ScreenTracker.shared

        for touch in touches where touch.phase == .began {
            guard let window = recordableWindow(of: touch, only: only) else { continue }
            let home = ScreenTracker.appWindow(in: window.windowScene) ?? window
            // A touch is the safety net for screen changes that happened
            // without a viewDidAppear (or while automatic tracking was off):
            // re-resolve the visible screen before attributing it.
            tracker.noteScreen(in: home)
            let element = ScreenTracker.element(for: touch.view)
            CrashCamLogger.shared.add(UserTapInfo(
                location: location(of: touch, in: window, home: home),
                timestamp: Date(),
                phase: .began,
                screen: tracker.currentScreen,
                element: element.name,
                elementId: element.id,
                touchId: assignFinger(to: touch, among: touches)
            ))
        }

        for touch in touches where touch.phase == .moved {
            guard let window = recordableWindow(of: touch, only: only),
                  let finger = fingers[ObjectIdentifier(touch)]
            else { continue }
            let home = ScreenTracker.appWindow(in: window.windowScene) ?? window
            CrashCamLogger.shared.add(UserTapInfo(
                location: location(of: touch, in: window, home: home),
                timestamp: Date(),
                phase: .moved,
                screen: tracker.currentScreen,
                touchId: finger
            ))
        }

        for touch in touches where touch.phase == .ended || touch.phase == .cancelled {
            guard let window = recordableWindow(of: touch, only: only),
                  let finger = fingers.removeValue(forKey: ObjectIdentifier(touch))
            else { continue }
            let home = ScreenTracker.appWindow(in: window.windowScene) ?? window
            CrashCamLogger.shared.add(UserTapInfo(
                location: location(of: touch, in: window, home: home),
                timestamp: Date(),
                phase: .ended,
                screen: tracker.currentScreen,
                touchId: finger
            ))
        }
    }

    // MARK: - Finger ids

    /// The finger id of every touch currently down, keyed by the `UITouch`
    /// object (UIKit keeps one object per finger from down to up).
    private static var fingers: [ObjectIdentifier: Int] = [:]

    /// Gives a new touch the lowest id not in use. Ids of touches that are no
    /// longer part of the event (their end was never seen) are released first.
    private static func assignFinger(to touch: UITouch, among touches: Set<UITouch>) -> Int {
        let live = Set(touches.map { ObjectIdentifier($0) })
        fingers = fingers.filter { live.contains($0.key) }
        var id = 0
        let used = Set(fingers.values)
        while used.contains(id) { id += 1 }
        fingers[ObjectIdentifier(touch)] = id
        return id
    }

    private static func recordableWindow(of touch: UITouch, only: UIWindow?) -> UIWindow? {
        guard let window = touch.window,
              only == nil || window === only,
              isRecordable(window)
        else { return nil }
        return window
    }

    private static func location(of touch: UITouch, in window: UIWindow, home: UIWindow) -> CGPoint {
        let point = touch.location(in: window)
        return window === home ? point : window.convert(point, to: home)
    }

    // MARK: - Which windows are the app's

    private static var recordableClasses: [ObjectIdentifier: Bool] = [:]

    /// Whether touches in `window` belong in a recording — see the header.
    static func isRecordable(_ window: UIWindow) -> Bool {
        if ScreenTracker.isCrashCamOverlay(window) { return false }
        let cls: AnyClass = type(of: window)
        let key = ObjectIdentifier(cls)
        if let known = recordableClasses[key] { return known }
        let result = cls == UIWindow.self || window is TrackingWindow || isShippedWithApp(cls)
        recordableClasses[key] = result
        return result
    }

    /// True for classes whose code lives inside the app bundle (the app
    /// itself, its embedded frameworks, statically linked packages).
    private static func isShippedWithApp(_ cls: AnyClass) -> Bool {
        let appPath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let classPath = Bundle(for: cls).bundleURL.resolvingSymlinksInPath().path
        return classPath == appPath || classPath.hasPrefix(appPath + "/")
    }
}

// MARK: - sendEvent hook

extension UIApplication {
    /// Exchanged with `sendEvent(_:)` once, at `TouchRecorder.installApplicationHook()`.
    /// Calling itself here calls the original implementation.
    @objc fileprivate func crashCam_sendEvent(_ event: UIEvent) {
        if TouchRecorder.isAutomatic { TouchRecorder.record(event) }
        crashCam_sendEvent(event)
    }
}

//
//  ScreenTracker.swift
//  CrashCam
//
//  Knows which screen the user is looking at, so every recorded event can say
//  where it happened and a viewer can cut the timeline into screens.
//
//  Two automatic signals, no app code required:
//    1. `UIViewController.viewDidAppear(_:)` is swizzled (the same public-API
//       technique analytics SDKs use for automatic screen views). After any
//       controller appears, the top-most visible controller of its window is
//       resolved — through presented, navigation, tab, split, page and
//       single-child containers — and a `.screenChange` row is written when its
//       name differs from the last one recorded.
//    2. Every touch-down re-checks the same thing as a safety net, so a screen
//       that appeared without `viewDidAppear` (or while tracking was off) is
//       still attributed correctly from the next touch on.
//
//  Names: a controller's class name (`BusJourneyListViewController`); a
//  `UIHostingController` reports its root SwiftUI view type
//  (`UIHostingController<ContentView>` → `ContentView`). Where that is not
//  meaningful — SwiftUI navigation destinations are hosted by internal types —
//  the app overrides the name with `CrashCam.shared.markScreen("Checkout")`,
//  the `.crashCamScreen("Checkout")` view modifier, or by setting a
//  controller's `crashCamScreenName`. A manual name sticks to the controller
//  instance it was set on, so the automatic path keeps reporting it.
//
//  Elements: for a touch-down the touched view is walked up to the nearest
//  meaningful ancestor (a control, a cell, a view with an accessibility
//  identifier, or the first non-UIKit class) and its class plus accessibility
//  identifier are recorded. Never a label, never text.
//

import ObjectiveC
import UIKit

@MainActor
public final class ScreenTracker {

    public static let shared = ScreenTracker()

    /// Automatic screen changes from `viewDidAppear`. On by default; set to
    /// false to record screens only from manual markers and touch-time
    /// resolution. Can be changed at any time.
    public var isAutomatic = true

    /// Name of the screen most recently recorded, if any.
    public private(set) var currentScreen: String?

    private var lastSize: CGSize?
    private var started = false

    private init() {}

    /// Installs the `viewDidAppear` hook. Idempotent; called from
    /// `CrashCam.bootstrap`.
    public func start() {
        guard !started else { return }
        started = true
        _ = UIViewController.crashCamInstallAppearanceHook
    }

    // MARK: - Automatic signals

    /// Called by the swizzled `viewDidAppear`. Only controllers in the app's
    /// own window count: the keyboard, text-effects and other system windows
    /// host UIKit-internal controllers whose appearance is not a screen change.
    func viewControllerDidAppear(_ controller: UIViewController) {
        guard isAutomatic,
              let window = controller.viewIfLoaded?.window,
              Self.isAppWindow(window)
        else { return }
        noteScreen(in: window)
    }

    /// Re-resolves the visible screen of `window` and records a change if its
    /// name or the window size differs from the last recorded row. Cheap
    /// enough to run on every touch-down.
    func noteScreen(in window: UIWindow?) {
        guard let window,
              let top = Self.topViewController(from: window.rootViewController)
        else { return }
        let name = Self.screenName(for: top)
        let size = window.bounds.size
        record(name, size: size, scale: window.screen.scale)
    }

    // MARK: - Manual marker

    /// Names the screen currently on top. The name is attached to that
    /// controller instance (`crashCamScreenName`) so later automatic checks
    /// keep reporting it, and a `.screenChange` row is written now.
    public func markScreen(_ name: String) {
        let window = Self.appWindow()
        if let window, let top = Self.topViewController(from: window.rootViewController) {
            top.crashCamScreenName = name
        }
        record(name, size: window?.bounds.size, scale: window?.screen.scale)
    }

    private func record(_ name: String, size: CGSize?, scale: CGFloat?) {
        guard name != currentScreen || (size != nil && size != lastSize) else { return }
        currentScreen = name
        if let size { lastSize = size }
        CrashCamLogger.shared.add(
            UserTapInfo(screenChangeTo: name, timestamp: Date(), screenSize: size, scale: scale)
        )
    }

    // MARK: - Resolution helpers

    /// Whether `window` is the app's content window rather than a system one
    /// (keyboard, text effects, status bar). A `TrackingWindow` always is; an
    /// app without one is judged by `appWindow()`.
    static func isAppWindow(_ window: UIWindow) -> Bool {
        window is TrackingWindow || window === appWindow()
    }

    /// The app's own window: the key `TrackingWindow` if there is one, else
    /// the key window, else the first window of any connected scene.
    static func appWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first { $0.isKeyWindow && $0 is TrackingWindow }
            ?? windows.first(where: \.isKeyWindow)
            ?? windows.first { $0 is TrackingWindow }
            ?? windows.first
    }

    /// The controller the user sees, starting from a window's root.
    static func topViewController(from root: UIViewController?) -> UIViewController? {
        var current = root
        var hops = 0
        while let controller = current, hops < 32 {
            hops += 1
            if let presented = controller.presentedViewController, !presented.isBeingDismissed {
                current = presented
                continue
            }
            if let navigation = controller as? UINavigationController {
                guard let top = navigation.topViewController else { break }
                current = top
                continue
            }
            if let tabs = controller as? UITabBarController {
                guard let selected = tabs.selectedViewController else { break }
                current = selected
                continue
            }
            if let split = controller as? UISplitViewController {
                guard let last = split.viewControllers.last else { break }
                current = last
                continue
            }
            if let pages = controller as? UIPageViewController {
                guard let first = pages.viewControllers?.first else { break }
                current = first
                continue
            }
            // A custom container showing exactly one full-size child: descend.
            if controller.children.count == 1,
               let only = controller.children.first,
               only.isViewLoaded,
               only.view.bounds.size == controller.view.bounds.size {
                current = only
                continue
            }
            break
        }
        return current
    }

    /// Manual name if the app set one, else the automatic name.
    static func screenName(for controller: UIViewController) -> String {
        if let manual = controller.crashCamScreenName, !manual.isEmpty {
            return manual
        }
        return automaticName(for: controller)
    }

    /// `String(describing:)` of the controller's type, reduced to something
    /// readable: generic wrappers are peeled (`UIHostingController<
    /// ModifiedContent<ContentView, …>>` → `ContentView`), and internal
    /// (`_`-prefixed) results fall back to the outer class name.
    static func automaticName(for controller: UIViewController) -> String {
        simplify(String(describing: type(of: controller)))
    }

    static func simplify(_ typeName: String) -> String {
        guard let open = typeName.firstIndex(of: "<"), typeName.hasSuffix(">") else {
            return typeName
        }
        let outer = String(typeName[..<open])
        var inner = String(typeName[typeName.index(after: open)..<typeName.index(before: typeName.endIndex)])
        // Peel wrapper generics down to the view type the developer wrote.
        var guardCount = 0
        while let wrapperOpen = inner.firstIndex(of: "<"), inner.hasSuffix(">"), guardCount < 16 {
            guardCount += 1
            let wrapper = String(inner[..<wrapperOpen])
            let arguments = topLevelArguments(
                String(inner[inner.index(after: wrapperOpen)..<inner.index(before: inner.endIndex)])
            )
            guard !arguments.isEmpty else { break }
            if wrapper == "NavigationStack" {
                inner = arguments.last!            // NavigationStack<Path, Root>
            } else if Self.peeledWrappers.contains(wrapper) || wrapper.hasPrefix("_") {
                inner = arguments[0]
            } else {
                inner = wrapper                    // a user view type with its own generics
            }
        }
        let name = inner.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.hasPrefix("_") || name.hasPrefix("(") {
            return outer
        }
        // A module-qualified name ("SwiftUI.AnyView") keeps only its last part.
        return name.split(separator: ".").last.map(String.init) ?? name
    }

    /// Generic wrappers that say nothing about *which* screen this is; their
    /// first argument is looked at instead. An anonymous layout root such as
    /// `VStack<TupleView<(…)>>` ends in a tuple, which falls back to the
    /// controller's class name — the cue to add `.crashCamScreen(_:)`.
    private static let peeledWrappers: Set<String> = [
        "ModifiedContent", "NavigationView", "AnyView", "Optional",
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "Group",
        "ScrollView", "List", "TupleView", "GeometryReader", "Form",
    ]

    /// Splits "A, B<C, D>, E" into ["A", "B<C, D>", "E"].
    private static func topLevelArguments(_ list: String) -> [String] {
        var result: [String] = []
        var depth = 0
        var current = ""
        for character in list {
            switch character {
            case "<": depth += 1; current.append(character)
            case ">": depth -= 1; current.append(character)
            case "," where depth == 0:
                result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    /// The touched element: the nearest meaningful ancestor of the hit view
    /// (see the header). Returns its class and accessibility identifier.
    static func element(for view: UIView?) -> (name: String, id: String?) {
        var current = view
        var hops = 0
        var first: (name: String, id: String?)?
        while let candidate = current, hops < 12 {
            hops += 1
            let name = Self.elementName(of: candidate)
            let id = candidate.accessibilityIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            if first == nil { first = (name, id) }
            if id != nil { return (name, id) }
            if candidate is UIControl || candidate is UITableViewCell || candidate is UICollectionViewCell {
                return (name, id)
            }
            if candidate is UIWindow { break }
            // A class the app wrote (not UIKit's, not SwiftUI's) is the answer.
            if name != "SwiftUI" && !name.hasPrefix("UI") && !name.hasPrefix("_") {
                return (name, id)
            }
            current = candidate.superview
        }
        return first ?? ("?", nil)
    }

    /// A view's class name for the recording. SwiftUI content draws into
    /// views from the SwiftUI module (hosting views, layout containers) whose
    /// names say nothing more than "SwiftUI", so that is what they report.
    private static func elementName(of view: UIView) -> String {
        let qualified = String(reflecting: type(of: view))
        if qualified.hasPrefix("SwiftUI.") || qualified.contains("HostingView") { return "SwiftUI" }
        return simplify(String(describing: type(of: view)))
    }
}

// MARK: - Manual screen names on controllers

nonisolated(unsafe) private var crashCamScreenNameKey: UInt8 = 0

public extension UIViewController {
    /// A screen name for this controller that overrides the automatic one
    /// (its class name). Set it in `viewDidLoad`, or use
    /// `CrashCam.shared.markScreen` for the controller currently on top.
    var crashCamScreenName: String? {
        get { objc_getAssociatedObject(self, &crashCamScreenNameKey) as? String }
        set { objc_setAssociatedObject(self, &crashCamScreenNameKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
}

// MARK: - viewDidAppear hook

extension UIViewController {
    /// Exchanged with `viewDidAppear(_:)` once, at `ScreenTracker.start()`.
    /// Calling itself here calls the original implementation.
    @objc fileprivate func crashCam_viewDidAppear(_ animated: Bool) {
        crashCam_viewDidAppear(animated)
        ScreenTracker.shared.viewControllerDidAppear(self)
    }

    static let crashCamInstallAppearanceHook: Void = {
        guard let original = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewDidAppear(_:))),
              let hook = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.crashCam_viewDidAppear(_:)))
        else { return }
        method_exchangeImplementations(original, hook)
    }()
}

// MARK: - SwiftUI marker

#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Names the screen this view represents for CrashCam recordings. Applied
    /// to a screen's root view, it records a screen change whenever the view
    /// appears — the way to name SwiftUI navigation destinations, whose
    /// hosting controllers have no meaningful class name.
    func crashCamScreen(_ name: String) -> some View {
        onAppear { ScreenTracker.shared.markScreen(name) }
    }
}
#endif

//
//  ReplayButton.swift
//  CrashCam
//
//  Debug-only floating button for starting a replay by hand, from wherever
//  the app currently is. Launch-argument replays always start at launch,
//  which suits a full recording; a clip cropped from the middle of a session
//  needs the app brought to the clip's first screen first, then started on
//  demand — that is this button.
//
//  Tapping it opens a menu: the last crash, the recordings in
//  Documents/CrashCam/replays/ (copy files there with the command the
//  dashboard's replay editor shows), a Files picker, and the speed. After a
//  3-2-1 countdown the replay runs from the first touch — never aligned to
//  the launch, since the launch is long past — and the button becomes Stop.
//
//  It lives in its own window above the app, like the replay pointer: its
//  touches never reach the TrackingWindow, so pressing it is not recorded,
//  and the replayer and screen tracker both skip the window. Everything
//  outside the bubble (and what it presents) is transparent to touches.
//

#if DEBUG

import UIKit
import UniformTypeIdentifiers

/// Passes every touch through except those on the bubble and on whatever the
/// button presents (the Files picker).
final class ReplayButtonWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === rootViewController?.view ? nil : hit
    }
}

/// Root of the button window. Defers status-bar appearance to the app's own
/// window, so a full-screen overlay window doesn't change it, and reports
/// size changes (first layout, rotation) so the bubble can be re-placed —
/// its position is only meaningful once the view has its real bounds.
private final class ReplayButtonRootViewController: UIViewController {
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero
    private var appRoot: UIViewController? { ScreenTracker.appWindow()?.rootViewController }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize, view.bounds.width > 0 else { return }
        lastSize = view.bounds.size
        onResize?()
    }
    override var preferredStatusBarStyle: UIStatusBarStyle { appRoot?.preferredStatusBarStyle ?? .default }
    override var prefersStatusBarHidden: Bool { appRoot?.prefersStatusBarHidden ?? false }
    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }
}

@MainActor
final class ReplayButtonController: NSObject {

    static let shared = ReplayButtonController()

    /// Where hand-picked recordings live; the menu lists every .json here.
    static var replaysFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrashCam/replays", isDirectory: true)
    }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? install() : uninstall()
        }
    }

    private enum State: Equatable { case idle, countdown(Int), replaying }

    private enum Style {
        static let size: CGFloat = 52
        static let margin: CGFloat = 10
        static let idleBackground = UIColor(white: 0.08, alpha: 0.82)
        static let stopBackground = UIColor.systemRed.withAlphaComponent(0.9)
        static let countdownSeconds = 3
    }

    private static let positionKey = "CrashCamReplayButtonPosition"

    private var window: ReplayButtonWindow?
    private let bubble = UIButton(type: .custom)
    private var state: State = .idle
    private var speed: Double = 1.0
    private var countdownTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var loggerWasPaused = false

    private override init() {
        super.init()
    }

    // MARK: - Install

    private func install() {
        try? FileManager.default.createDirectory(at: Self.replaysFolder, withIntermediateDirectories: true)
        // Bootstrap runs before any scene connects: install as soon as one is
        // there, and again if the app's scene comes back.
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachIfPossible() }
            })
        }
        attachIfPossible()
    }

    private func uninstall() {
        countdownTask?.cancel()
        countdownTask = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window?.isHidden = true
        window = nil
    }

    private func attachIfPossible() {
        guard isEnabled else { return }
        guard let appWindow = ScreenTracker.appWindow(), let scene = appWindow.windowScene else { return }
        if let window, window.windowScene === scene, !window.isHidden { return }

        let overlay = ReplayButtonWindow(windowScene: scene)
        overlay.frame = scene.coordinateSpace.bounds
        // Below the replay pointer (alert + 1), above the app and its alerts.
        overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 0.5)
        overlay.backgroundColor = .clear
        let root = ReplayButtonRootViewController()
        root.onResize = { [weak self] in self?.placeBubble(animated: false) }
        overlay.rootViewController = root
        configureBubble()
        root.view.addSubview(bubble)
        overlay.isHidden = false // shown, never made key
        window = overlay
        print("CrashCam: replay button on — recordings in \(Self.replaysFolder.path)")
    }

    // MARK: - Bubble

    private var bubbleConfigured = false

    private func configureBubble() {
        guard !bubbleConfigured else { return }
        bubbleConfigured = true
        bubble.frame = CGRect(x: 0, y: 0, width: Style.size, height: Style.size)
        bubble.layer.cornerRadius = Style.size / 2
        bubble.layer.borderWidth = 1
        bubble.layer.borderColor = UIColor(white: 1, alpha: 0.22).cgColor
        bubble.layer.shadowColor = UIColor.black.cgColor
        bubble.layer.shadowOpacity = 0.35
        bubble.layer.shadowRadius = 6
        bubble.layer.shadowOffset = CGSize(width: 0, height: 2)
        bubble.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 24, weight: .bold)
        bubble.accessibilityLabel = "CrashCam replay"
        bubble.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .primaryActionTriggered)
        bubble.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        bubble.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated { completion(self?.menuItems() ?? []) }
        }])
        render()
    }

    private func render() {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        switch state {
        case .idle:
            bubble.backgroundColor = Style.idleBackground
            bubble.setTitle(nil, for: .normal)
            bubble.setImage(UIImage(systemName: "play.fill", withConfiguration: config), for: .normal)
            bubble.tintColor = .systemOrange
            bubble.showsMenuAsPrimaryAction = true
            bubble.alpha = 1
        case .countdown(let n):
            bubble.backgroundColor = Style.idleBackground
            bubble.setImage(nil, for: .normal)
            bubble.setTitle("\(n)", for: .normal)
            bubble.setTitleColor(.systemOrange, for: .normal)
            bubble.showsMenuAsPrimaryAction = false
            bubble.alpha = 1
        case .replaying:
            bubble.backgroundColor = Style.stopBackground
            bubble.setTitle(nil, for: .normal)
            bubble.setImage(UIImage(systemName: "stop.fill", withConfiguration: config), for: .normal)
            bubble.tintColor = .white
            bubble.showsMenuAsPrimaryAction = false
            bubble.alpha = 0.75 // the replay is what matters now
        }
        bubble.accessibilityHint = switch state {
        case .idle: "Shows the recordings to replay"
        case .countdown: "Cancels the replay before it starts"
        case .replaying: "Stops the replay"
        }
    }

    /// Only reached while counting down or replaying — when idle, a tap
    /// opens the menu instead.
    private func primaryTapped() {
        switch state {
        case .countdown:
            countdownTask?.cancel()
            countdownTask = nil
            state = .idle
            render()
            print("CrashCam replay: cancelled before it started")
        case .replaying:
            TouchReplayer.shared.stop()
        case .idle:
            break
        }
    }

    // Dragging moves the bubble; letting go snaps it to the nearer side and
    // remembers where it is (side + relative height) for the next launch.
    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let host = bubble.superview else { return }
        let translation = pan.translation(in: host)
        bubble.center = CGPoint(x: bubble.center.x + translation.x, y: bubble.center.y + translation.y)
        pan.setTranslation(.zero, in: host)
        if pan.state == .ended || pan.state == .cancelled {
            let bounds = host.bounds.inset(by: host.safeAreaInsets)
            let side = bubble.center.x < bounds.midX ? 0.0 : 1.0
            let relativeY = bounds.height > 0 ? (bubble.center.y - bounds.minY) / bounds.height : 0.5
            UserDefaults.standard.set([side, Double(min(max(relativeY, 0), 1))], forKey: Self.positionKey)
            placeBubble(animated: true)
        }
    }

    private func placeBubble(animated: Bool) {
        guard let host = bubble.superview, host.bounds.width > 0 else { return }
        let saved = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double]
        let side = saved?.first ?? 1
        let relativeY = saved?.last ?? 0.72
        let bounds = host.bounds.inset(by: host.safeAreaInsets)
            .insetBy(dx: Style.margin + Style.size / 2, dy: Style.margin + Style.size / 2)
        let center = CGPoint(x: side < 0.5 ? bounds.minX : bounds.maxX,
                             y: bounds.minY + bounds.height * relativeY)
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8,
                           initialSpringVelocity: 0.4) { self.bubble.center = center }
        } else {
            bubble.center = center
        }
    }

    // MARK: - Menu

    private struct Entry {
        let url: URL
        let touches: Int
        let duration: TimeInterval
        let modified: Date?
    }

    private func entry(for url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([UserTapInfo].self, from: data)
        else { return nil }
        let touches = rows.filter { $0.kind == .touch }
        guard let first = touches.first, let last = touches.last else {
            return Entry(url: url, touches: 0, duration: 0, modified: nil)
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return Entry(url: url,
                     touches: touches.filter { $0.phase == .began }.count,
                     duration: last.timestamp.timeIntervalSince(first.timestamp),
                     modified: modified)
    }

    private func subtitle(_ e: Entry) -> String {
        var parts = ["\(e.touches) touch\(e.touches == 1 ? "" : "es")", String(format: "%.1f s", e.duration)]
        if let modified = e.modified {
            parts.append(RelativeDateTimeFormatter().localizedString(for: modified, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    private func menuItems() -> [UIMenuElement] {
        var sections: [UIMenuElement] = []

        // The app's own last crash.
        let last = CrashCamLogger.shared.replayFileURL
        let lastEntry = FileManager.default.fileExists(atPath: last.path) ? entry(for: last) : nil
        let lastAction = UIAction(title: "Replay last crash",
                                  subtitle: lastEntry.map(subtitle) ?? "No crash recording yet",
                                  image: UIImage(systemName: "exclamationmark.triangle"),
                                  attributes: (lastEntry?.touches ?? 0) > 0 ? [] : .disabled) { [weak self] _ in
            self?.start(last)
        }

        // Files copied into Documents/CrashCam/replays, newest first.
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: Self.replaysFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap(entry(for:))
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        let fileActions: [UIMenuElement] = files.prefix(12).map { e in
            UIAction(title: e.url.deletingPathExtension().lastPathComponent,
                     subtitle: subtitle(e),
                     image: UIImage(systemName: "doc.text"),
                     attributes: e.touches > 0 ? [] : .disabled) { [weak self] _ in
                self?.start(e.url)
            }
        }
        sections.append(UIMenu(title: "", options: .displayInline, children: [lastAction] + fileActions))

        let choose = UIAction(title: "Choose file…", image: UIImage(systemName: "folder")) { [weak self] _ in
            self?.presentPicker()
        }
        let speeds: [UIMenuElement] = [0.5, 1, 2, 4].map { value in
            UIAction(title: value == 0.5 ? "0.5×" : "\(Int(value))×",
                     state: value == speed ? .on : .off) { [weak self] _ in self?.speed = value }
        }
        let speedMenu = UIMenu(title: "Speed", subtitle: speed == 0.5 ? "0.5×" : "\(Int(speed))×",
                               image: UIImage(systemName: "speedometer"),
                               options: .singleSelection, children: speeds)
        let hide = UIAction(title: "Hide until next launch", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
            self?.isEnabled = false
        }
        sections.append(UIMenu(title: "", options: .displayInline, children: [choose, speedMenu, hide]))
        return sections
    }

    // MARK: - Files picker

    private func presentPicker() {
        guard let root = window?.rootViewController else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        // The picker's search field would otherwise be recorded as text edits.
        loggerWasPaused = CrashCamLogger.shared.isPaused
        CrashCamLogger.shared.isPaused = true
        root.present(picker, animated: true)
    }

    private func pickerFinished() {
        // Typing in the picker can make this window key; hand it back.
        ScreenTracker.appWindow()?.makeKey()
        // Resume recording once the dismissal is over: the picker's keyboard
        // posts its will-hide notification on the way out, which would
        // otherwise land in the session as a keyboard-hide row.
        let resume = loggerWasPaused
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !TouchReplayer.shared.isReplaying { CrashCamLogger.shared.isPaused = resume }
        }
    }

    // MARK: - Replay

    private func start(_ url: URL) {
        guard state == .idle else { return }
        countdownTask = Task { @MainActor [weak self] in
            for n in stride(from: Style.countdownSeconds, through: 1, by: -1) {
                guard let self else { return }
                self.state = .countdown(n)
                self.render()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            self?.run(url)
        }
    }

    private func run(_ url: URL) {
        countdownTask = nil
        state = .replaying
        render()
        let started = CrashCam.shared.replayFromHere(fileURL: url, speed: speed) { [weak self] in
            self?.state = .idle
            self?.render()
        }
        if !started {
            state = .idle
            render()
        }
    }
}

extension ReplayButtonController: UIDocumentPickerDelegate {
    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        MainActor.assumeIsolated {
            pickerFinished()
            guard let picked = urls.first else { return }
            // Keep a copy in the replays folder so it is in the menu next time.
            let target = Self.replaysFolder.appendingPathComponent(picked.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.copyItem(at: picked, to: target)
                start(target)
            } catch {
                print("CrashCam replay: could not copy \(picked.lastPathComponent) into \(Self.replaysFolder.path): \(error.localizedDescription)")
                start(picked)
            }
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        MainActor.assumeIsolated { pickerFinished() }
    }
}

#endif

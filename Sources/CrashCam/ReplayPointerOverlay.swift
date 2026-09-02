//
//  ReplayPointerOverlay.swift
//  CrashCam
//
//  Debug-only visual pointer for in-process replay: a translucent disc that
//  appears where a synthetic touch lands, follows it while it drags (leaving
//  a short fading trail), and ripples out when it lifts — so a replay can be
//  watched instead of inferred from how the app reacts.
//
//  The pointer lives in its own pass-through window stacked above the app's
//  window, never inside the app's view hierarchy: the synthesizer hit-tests
//  the tracking window to bind each touch's target view, and an extra subview
//  there could change what it finds. The window returns nil from hitTest, so
//  real touches fall straight through to the app while it is up.
//

#if DEBUG

import UIKit

/// Transparent window that only draws; every hit test falls through to the
/// windows beneath it.
final class ReplayPointerWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

@MainActor
final class ReplayPointerOverlay {

    private enum Style {
        static let discDiameter: CGFloat = 44
        static let fill = UIColor.systemOrange.withAlphaComponent(0.55)
        static let trailDiameter: CGFloat = 10
        static let trailFade: TimeInterval = 0.6
        static let pressDuration: TimeInterval = 0.08
        static let liftDuration: TimeInterval = 0.3
    }

    private var window: ReplayPointerWindow?
    private var disc: UIView?

    // MARK: - Lifecycle

    /// Puts the overlay above `source` (same scene, same frame). Replaces any
    /// overlay still fading out from a previous replay.
    func attach(above source: UIWindow) {
        detachNow()

        let overlay: ReplayPointerWindow
        if let scene = source.windowScene {
            overlay = ReplayPointerWindow(windowScene: scene)
        } else {
            overlay = ReplayPointerWindow(frame: source.frame)
        }
        overlay.frame = source.frame
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false

        // An empty root keeps UIKit's window bookkeeping (rotation, warnings)
        // happy; the pointer views are added to the window itself so their
        // coordinates are plain window coordinates.
        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        overlay.rootViewController = root

        overlay.isHidden = false // shown, never made key
        window = overlay
    }

    /// Hides and releases the overlay once the last lift animation has had
    /// time to play out.
    func detach(after delay: TimeInterval) {
        guard let overlay = window else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.window === overlay else { return } // a new replay took over
            self.detachNow()
        }
    }

    private func detachNow() {
        disc?.removeFromSuperview()
        disc = nil
        if let overlay = window {
            overlay.isHidden = true
            overlay.windowScene = nil
        }
        window = nil
    }

    // MARK: - Touch mirroring (points in `source` window coordinates)

    func touchBegan(at point: CGPoint, in source: UIWindow) {
        guard let overlay = window else { return }
        disc?.removeFromSuperview()

        let view = Self.makeDisc()
        view.center = source.convert(point, to: overlay)
        view.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        view.alpha = 0
        overlay.addSubview(view)
        disc = view

        UIView.animate(withDuration: Style.pressDuration) {
            view.transform = .identity
            view.alpha = 1
        }
    }

    func touchMoved(to point: CGPoint, in source: UIWindow) {
        guard let overlay = window else { return }
        let center = source.convert(point, to: overlay)
        guard let disc else {
            touchBegan(at: point, in: source) // a stroke we never saw start
            return
        }
        disc.center = center
        dropTrailDot(at: center, below: disc, in: overlay)
    }

    func touchEnded(at point: CGPoint, in source: UIWindow) {
        guard let overlay = window, let view = disc else { return }
        disc = nil
        view.center = source.convert(point, to: overlay)
        UIView.animate(withDuration: Style.liftDuration, animations: {
            view.transform = CGAffineTransform(scaleX: 1.7, y: 1.7)
            view.alpha = 0
        }, completion: { _ in
            view.removeFromSuperview()
        })
    }

    func touchCancelled() {
        guard let view = disc else { return }
        disc = nil
        UIView.animate(withDuration: Style.liftDuration / 2, animations: {
            view.alpha = 0
        }, completion: { _ in
            view.removeFromSuperview()
        })
    }

    // MARK: - Drawing

    private func dropTrailDot(at center: CGPoint, below disc: UIView, in overlay: UIWindow) {
        let d = Style.trailDiameter
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: d, height: d))
        dot.center = center
        dot.backgroundColor = Style.fill
        dot.layer.cornerRadius = d / 2
        dot.isUserInteractionEnabled = false
        overlay.insertSubview(dot, belowSubview: disc)
        UIView.animate(withDuration: Style.trailFade, animations: {
            dot.alpha = 0
        }, completion: { _ in
            dot.removeFromSuperview()
        })
    }

    /// Orange disc with a white rim and a centre mark: readable on light and
    /// dark content alike, and the centre pinpoints the exact touch location.
    private static func makeDisc() -> UIView {
        let d = Style.discDiameter
        let view = UIView(frame: CGRect(x: 0, y: 0, width: d, height: d))
        view.isUserInteractionEnabled = false
        view.backgroundColor = Style.fill
        view.layer.cornerRadius = d / 2
        view.layer.borderWidth = 2
        view.layer.borderColor = UIColor.white.cgColor
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.35
        view.layer.shadowRadius = 3
        view.layer.shadowOffset = .zero

        let mark: CGFloat = 6
        let centre = UIView(frame: CGRect(x: (d - mark) / 2, y: (d - mark) / 2, width: mark, height: mark))
        centre.backgroundColor = .white
        centre.layer.cornerRadius = mark / 2
        centre.layer.borderWidth = 1
        centre.layer.borderColor = UIColor.black.withAlphaComponent(0.5).cgColor
        view.addSubview(centre)
        return view
    }
}

#endif

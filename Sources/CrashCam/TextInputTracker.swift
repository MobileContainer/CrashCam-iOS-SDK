//
//  TextInputTracker.swift
//  CrashCam
//
//  Records text-field / text-view edits as length-only events, interleaved with
//  the touch stream. We observe the global `textDidChangeNotification`s rather
//  than wiring each field's delegate, so any field in the app is covered with no
//  host-app changes. Only the current character count is captured — never the
//  typed text — and it goes through `CrashCamLogger.add` like a touch, so each
//  change is durably on disk before a potential mid-edit crash (the same
//  reason touches are written synchronously).
//

import UIKit

@MainActor
public final class TextInputTracker: NSObject {

    public static let shared = TextInputTracker()

    private var started = false

    private override init() { super.init() }

    /// Begin observing text edits. Idempotent; called from `CrashCam.bootstrap`
    /// once the recording session is clean.
    public func start() {
        guard !started else { return }
        started = true

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(textFieldChanged(_:)),
                       name: UITextField.textDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(textViewChanged(_:)),
                       name: UITextView.textDidChangeNotification, object: nil)
        // Keyboard dismissal: the keyboard's own keys live in a separate system
        // window, so a Return/Done tap never reaches TrackingWindow — this is the
        // only signal that the keyboard closed. `willHide` fires at the moment of
        // the trigger, so its timestamp lines up with the user's action.
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func textFieldChanged(_ note: Notification) {
        guard let field = note.object as? UITextField else { return }
        record(view: field, length: field.text?.count ?? 0)
    }

    @objc private func textViewChanged(_ note: Notification) {
        guard let view = note.object as? UITextView else { return }
        record(view: view, length: view.text?.count ?? 0)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        CrashCamLogger.shared.add(UserTapInfo(keyboardHideAt: Date()))
    }

    private func record(view: UIView, length: Int) {
        // Field origin in window coordinates — informational only (replay types
        // into the focused element, not this point). Never includes any text.
        let origin = view.convert(view.bounds, to: nil).origin
        CrashCamLogger.shared.add(
            UserTapInfo(textChangeAt: origin, timestamp: Date(), textLength: length)
        )
    }
}

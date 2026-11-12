//
//  TrackingWindow.swift
//  CrashCam
//
//  Created by Metin Tarık Kiki on 28.12.2025.
//

import UIKit

/// The original way to record touches: install this as the app's window.
///
/// Since SDK 2.1.0 it is no longer needed — `CrashCam.bootstrap()` records
/// every touch through an application-level hook (see `TouchRecorder`) — and
/// apps that still use it keep working unchanged: while that hook is
/// recording, this window records nothing itself, so no touch is written
/// twice. It records on its own only when the hook is not in charge
/// (`CrashCam.shared.automaticTouchRecording = false`, or `bootstrap()` has
/// not run).
public final class TrackingWindow: UIWindow {

    public override func sendEvent(_ event: UIEvent) {
        // Record BEFORE forwarding: the crash-causing handler runs inside
        // super.sendEvent, so recording afterwards loses the fatal touch.
        if !TouchRecorder.applicationHookRecords {
            TouchRecorder.record(event, only: self)
        }
        super.sendEvent(event)
    }
}

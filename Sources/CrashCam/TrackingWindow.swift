//
//  TrackingWindow.swift
//  CrashCam
//
//  Created by Metin Tarık Kiki on 28.12.2025.
//

import UIKit

public final class TrackingWindow: UIWindow {

    public override func sendEvent(_ event: UIEvent) {
        // Record BEFORE forwarding. The crash this tool exists to capture is
        // usually raised synchronously by a handler of this very event (a
        // button action or gesture callback runs inside super.sendEvent), so
        // recording after forwarding loses the final — fatal — touch. The
        // in-process replayer still synthesizes a missing touch-up when
        // replaying logs recorded before this fix.
        if event.type == .touches,
           let touches = event.allTouches {

            let tracker = ScreenTracker.shared

            for touch in touches where touch.phase == .began {
                // A touch is the safety net for screen changes that happened
                // without a viewDidAppear (or while automatic tracking was
                // off): re-resolve the visible screen before attributing it.
                tracker.noteScreen(in: self)
                let location = touch.location(in: touch.window)
                let element = ScreenTracker.element(for: touch.view)
                let info = UserTapInfo(
                    location: location,
                    timestamp: Date(),
                    phase: .began,
                    screen: tracker.currentScreen,
                    element: element.name,
                    elementId: element.id
                )
                CrashCamLogger.shared.add(info)
            }

            for touch in touches where touch.phase == .moved {
                let location = touch.location(in: touch.window)
                let info = UserTapInfo(
                    location: location,
                    timestamp: Date(),
                    phase: .moved,
                    screen: tracker.currentScreen
                )
                CrashCamLogger.shared.add(info)
            }

            for touch in touches where touch.phase == .ended {
                let location = touch.location(in: touch.window)
                let info = UserTapInfo(
                    location: location,
                    timestamp: Date(),
                    phase: .ended,
                    screen: tracker.currentScreen
                )
                CrashCamLogger.shared.add(info)
            }
        }

        super.sendEvent(event)
    }
}

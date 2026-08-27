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

            for touch in touches where touch.phase == .began {
                let location = touch.location(in: touch.window)
                let info = UserTapInfo(
                    location: location,
                    timestamp: Date(),
                    phase: .began
                )
                CrashCamLogger.shared.add(info)
            }


            for touch in touches where touch.phase == .moved {
                let location = touch.location(in: touch.window)
                let info = UserTapInfo(
                    location: location,
                    timestamp: Date(),
                    phase: .moved
                )
                CrashCamLogger.shared.add(info)
            }



            for touch in touches where touch.phase == .ended {
                let location = touch.location(in: touch.window)
                let info = UserTapInfo(
                    location: location,
                    timestamp: Date(),
                    phase: .ended
                )
                CrashCamLogger.shared.add(info)
            }
        }

        super.sendEvent(event)
    }
}

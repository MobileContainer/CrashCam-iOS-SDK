//
//  TouchReplayer.swift
//  CrashCam
//
//  Debug-only, in-process replay of a recorded touch session.
//
//  Why not Appium/XCUITest for this: every WebDriver command is an HTTP round
//  trip through WebDriverAgent (100–300ms+), and XCUITest adds quiescence
//  waits between events, so recorded timing can never be reproduced 1:1.
//  Here the recorded events are re-synthesized as real UITouch objects
//  (CrashCamTouchSynthesis target) and delivered through
//  UIApplication.sendEvent(_:) on a CADisplayLink, so playback resolution is
//  bounded only by the display refresh (~8ms at 120Hz, ~16ms at 60Hz) and the
//  events flow through the real responder chain — gesture recognizers, UIKit
//  controls, and SwiftUI gestures all behave as if a finger did it.
//

#if DEBUG

import UIKit
import CrashCamTouchSynthesis

/// Replays recorded `UserTapInfo` touch events by synthesizing UITouches and
/// sending them through the app's own event pipeline.
///
/// Touches only for now: `textChange` / `keyboardHide` rows are skipped (the
/// keyboard lives in its own window, so typing was never recorded as touches;
/// in-process text replay is a separate, future step).
@MainActor
public final class TouchReplayer {

    public static let shared = TouchReplayer()
    private init() {}

    public private(set) var isReplaying = false

    private struct ScheduledEvent {
        let phase: UserTapInfo.Phase
        let point: CGPoint
        let offset: TimeInterval // seconds since the first recorded event
    }

    private var events: [ScheduledEvent] = []
    private var cursor = 0
    private var startTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    // The schema carries no finger id (recordings are single-finger), so at
    // most one synthetic touch is alive at a time — the same stroke model the
    // Appium replay scripts use.
    private var activeTouch: UITouch?
    private var lastPoint: CGPoint = .zero
    private var maxLateness: TimeInterval = 0
    private weak var window: UIWindow?
    private var completion: (() -> Void)?

    /// Starts replaying. Only `kind == .touch` rows are used. Recording is
    /// paused for the duration: the synthetic touches flow back through
    /// `TrackingWindow.sendEvent` and would otherwise be re-recorded.
    public func replay(_ recording: [UserTapInfo],
                       in window: UIWindow,
                       speed: Double = 1.0,
                       completion: (() -> Void)? = nil) {
        guard !isReplaying else { return }

        let touches = recording.filter { $0.kind == .touch }
        let skipped = recording.count - touches.count
        if skipped > 0 {
            print("CrashCam replay: skipping \(skipped) non-touch event(s) — touches-only replayer")
        }
        guard let first = touches.first else {
            print("CrashCam replay: no touch events to replay")
            completion?()
            return
        }

        let t0 = first.timestamp
        events = touches
            .map {
                ScheduledEvent(phase: $0.phase,
                               point: $0.location,
                               offset: $0.timestamp.timeIntervalSince(t0) / speed)
            }
            .sorted { $0.offset < $1.offset }

        warnIfRecordingExceeds(window)

        self.window = window
        self.completion = completion
        cursor = 0
        activeTouch = nil
        maxLateness = 0
        isReplaying = true
        CrashCamLogger.shared.isPaused = true
        startTime = CACurrentMediaTime()
        print("CrashCam replay: \(events.count) touch events over "
              + String(format: "%.2f", events.last?.offset ?? 0) + "s")

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Highest refresh the display offers = best timing resolution.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                        maximum: 120,
                                                        preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stops early; a finger still down is cancelled so UIKit state is clean.
    public func stop() {
        if let touch = activeTouch {
            touch.crs_setPhase(.cancelled)
            CRSTouchSender.send([touch])
            activeTouch = nil
        }
        finish()
    }

    private func finish() {
        displayLink?.invalidate()
        displayLink = nil
        isReplaying = false
        CrashCamLogger.shared.isPaused = false
        let done = completion
        completion = nil
        done?()
    }

    // MARK: - Scheduling

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - startTime

        // Fire everything due this frame, in recorded order.
        while cursor < events.count, events[cursor].offset <= elapsed {
            maxLateness = max(maxLateness, elapsed - events[cursor].offset)
            fire(events[cursor])
            cursor += 1
        }

        if cursor >= events.count {
            // A recording can end mid-stroke: the crash typically happens
            // *inside* a handler of the final touch, killing the process
            // before its up/ended was persisted. Close the stroke so that
            // final gesture actually fires — the in-process equivalent of the
            // synthesized pointerUp the Appium scripts append.
            if let touch = activeTouch {
                touch.crs_move(to: lastPoint)
                touch.crs_setPhase(.ended)
                CRSTouchSender.send([touch])
                activeTouch = nil
            }
            reportStats(elapsed: elapsed)
            finish()
        }
    }

    private func fire(_ e: ScheduledEvent) {
        guard let window else { return }
        lastPoint = e.point

        switch e.phase {
        case .began:
            // A began while a stroke is open means its ended was never
            // recorded — close the old stroke before starting the new one.
            if let touch = activeTouch {
                touch.crs_setPhase(.ended)
                CRSTouchSender.send([touch])
            }
            guard let touch = UITouch.crs_touchBeginning(at: e.point, window: window) else { return }
            activeTouch = touch
            CRSTouchSender.send([touch])

        case .moved:
            guard let touch = activeTouch else { return }
            touch.crs_move(to: e.point)
            CRSTouchSender.send([touch])

        case .ended:
            guard let touch = activeTouch else { return }
            touch.crs_move(to: e.point) // final position
            touch.crs_setPhase(.ended)
            CRSTouchSender.send([touch])
            activeTouch = nil
        }
    }

    // Recordings store raw window coordinates, so one captured on a different
    // screen size lands in the wrong places — the common case being a
    // recording downloaded from the dashboard that came off another device.
    // Nothing is rescaled (that would replay input the user never made); this
    // just makes the mismatch obvious in the log instead of leaving a replay
    // that silently misses its targets.
    //
    // Heuristic, and only one-directional: recorded points outside this
    // window prove a mismatch, but a recording from a *larger* screen that
    // happens to stay inside these bounds passes unnoticed. Compare the two
    // sizes below when a replay behaves oddly.
    private func warnIfRecordingExceeds(_ window: UIWindow) {
        let points = events.map(\.point)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
        else { return }

        let bounds = window.bounds
        let recorded = String(format: "x %.0f…%.0f, y %.0f…%.0f", minX, maxX, minY, maxY)
        let current = String(format: "%.0f×%.0f", bounds.width, bounds.height)

        if minX < bounds.minX || maxX > bounds.maxX || minY < bounds.minY || maxY > bounds.maxY {
            print("""
                CrashCam replay: ⚠️ recorded touches (\(recorded)) fall outside this \
                window (\(current)) — the recording was almost certainly made on a \
                different screen size. Replaying the raw coordinates anyway; expect \
                touches to miss their targets.
                """)
        } else {
            print("CrashCam replay: touch extent \(recorded) within window \(current)")
        }
    }

    // Timing evidence for the "can this replay 1:1?" question: end-to-end
    // drift plus the worst single-event lateness, printed and written to
    // Documents so a headless run can read them back.
    private func reportStats(elapsed: TimeInterval) {
        let expected = events.last?.offset ?? 0
        let summary = String(
            format: "CrashCam replay finished: %d events, expected %.3fs, actual %.3fs, end drift %+.1fms, max event lateness %.1fms",
            events.count, expected, elapsed, (elapsed - expected) * 1000, maxLateness * 1000
        )
        print(summary)
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("replay_stats.txt")
        try? summary.write(to: url, atomically: true, encoding: .utf8)
    }
}

#endif

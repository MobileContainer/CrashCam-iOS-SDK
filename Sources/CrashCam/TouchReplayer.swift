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
/// Multi-finger gestures (pinch, rotate, two-finger pan) replay as recorded
/// when the rows carry a `touchId`. Touches only for now: `textChange` / `keyboardHide` rows are skipped (the
/// keyboard lives in its own window, so typing was never recorded as touches;
/// in-process text replay is a separate, future step).
@MainActor
public final class TouchReplayer {

    public static let shared = TouchReplayer()
    private init() {}

    public private(set) var isReplaying = false

    /// Draws a translucent disc wherever a synthetic touch lands — following
    /// drags and rippling out on lift — so the replay can be watched on
    /// screen instead of inferred from the app's reaction. On by default;
    /// set to false before calling `replay` to run invisibly.
    public var showsPointer = true
    private let pointer = ReplayPointerOverlay()

    private struct ScheduledEvent {
        let phase: UserTapInfo.Phase
        let point: CGPoint
        let offset: TimeInterval // seconds since the first recorded event
        let finger: Int          // the row's touchId; 0 when it has none
    }

    /// A synthetic finger that is currently down.
    private struct Finger {
        let touch: UITouch
        var point: CGPoint
    }

    private var events: [ScheduledEvent] = []
    private var cursor = 0
    private var startTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    // One synthetic touch per finger id (`touchId`, recorded since SDK 2.2.0),
    // so a pinch replays as two fingers. Rows without an id — older iOS
    // recordings — all share finger 0, which is the single-finger stroke
    // model those recordings were always replayed with.
    private var fingers: [Int: Finger] = [:]
    // Rows the recorder wrote from one touch event are microseconds apart;
    // rows this close together (in replay time) for different fingers are
    // delivered as one event again, as UIKit delivered them originally.
    private var batchWindow: TimeInterval = 0.004
    private var maxLateness: TimeInterval = 0
    // Launch alignment: when the recording has a session-start row and the
    // caller says when *this* process launched, event offsets are measured
    // from the session start and the timeline origin is pinned to the launch,
    // so the first touch fires the same time after launch as it was recorded.
    private var launchReference: CFTimeInterval?
    private var alignedToLaunch = false
    private var firstFireTime: CFTimeInterval?
    private weak var window: UIWindow?
    private var completion: (() -> Void)?

    /// Starts replaying. Only `kind == .touch` rows are used. Recording is
    /// paused for the duration: the synthetic touches flow back through
    /// `TrackingWindow.sendEvent` and would otherwise be re-recorded.
    ///
    /// `launchReference` is the media time at which this process started its
    /// recording session (see `CrashCam.bootstrap`). When it is given and the
    /// recording carries a session-start row, the first touch is fired at the
    /// same delay after launch as it was recorded — or immediately if that
    /// moment has already passed. Without either, the first touch fires now.
    public func replay(_ recording: [UserTapInfo],
                       in window: UIWindow,
                       speed: Double = 1.0,
                       launchReference: CFTimeInterval? = nil,
                       completion: (() -> Void)? = nil) {
        guard !isReplaying else { return }

        let touches = recording.filter { $0.kind == .touch }
        let sessionStart = recording.first { $0.kind == .sessionStart }
        let skipped = recording.filter { $0.kind != .touch && $0.kind != .sessionStart }.count
        if skipped > 0 {
            print("CrashCam replay: skipping \(skipped) non-touch event(s) — touches-only replayer")
        }
        guard let first = touches.first else {
            print("CrashCam replay: no touch events to replay")
            completion?()
            return
        }

        alignedToLaunch = sessionStart != nil && launchReference != nil
        self.launchReference = launchReference
        let origin = alignedToLaunch ? sessionStart!.timestamp : first.timestamp
        events = touches
            .map {
                ScheduledEvent(phase: $0.phase,
                               point: $0.location,
                               offset: $0.timestamp.timeIntervalSince(origin) / speed,
                               finger: $0.touchId ?? 0)
            }
            .sorted { $0.offset < $1.offset }

        warnIfRecordingExceeds(window)

        self.window = window
        self.completion = completion
        if showsPointer {
            pointer.attach(above: window)
        }
        cursor = 0
        fingers = [:]
        batchWindow = 0.004 / max(speed, 0.01)
        maxLateness = 0
        firstFireTime = nil
        isReplaying = true
        CrashCamLogger.shared.isPaused = true

        let now = CACurrentMediaTime()
        let firstOffset = events[0].offset
        if alignedToLaunch, let launchReference {
            let due = launchReference + firstOffset
            if due > now {
                // Pin the timeline's origin to the launch: the first touch
                // then fires exactly firstOffset after it, as recorded.
                startTime = launchReference
                print(String(format: "CrashCam replay: first touch was recorded %.2fs after launch — waiting %.2fs to match",
                             firstOffset, due - now))
            } else {
                startTime = now - firstOffset
                print(String(format: "CrashCam replay: first touch was recorded %.2fs after launch, but launch was %.2fs ago — starting now",
                             firstOffset, now - launchReference))
            }
        } else {
            startTime = now
        }
        print("CrashCam replay: \(events.count) touch events over "
              + String(format: "%.2f", (events.last?.offset ?? 0) - firstOffset) + "s")

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Highest refresh the display offers = best timing resolution.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                        maximum: 120,
                                                        preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stops early; fingers still down are cancelled so UIKit state is clean.
    public func stop() {
        if !fingers.isEmpty {
            pointer.touchCancelled()
            let touches = orderedTouches()
            touches.forEach { $0.crs_setPhase(.cancelled) }
            CRSTouchSender.send(touches)
            fingers = [:]
        }
        finish()
    }

    private func finish() {
        pointer.detach(after: 0.5)
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

        // Fire everything due this frame, in recorded order. Rows of
        // different fingers recorded at (practically) the same instant came
        // from one touch event and go out as one event.
        while cursor < events.count, events[cursor].offset <= elapsed {
            var batch = [events[cursor]]
            cursor += 1
            while cursor < events.count,
                  events[cursor].offset <= elapsed,
                  events[cursor].offset - batch[0].offset < batchWindow,
                  !batch.contains(where: { $0.finger == events[cursor].finger }) {
                batch.append(events[cursor])
                cursor += 1
            }
            maxLateness = max(maxLateness, elapsed - batch[0].offset)
            if firstFireTime == nil { firstFireTime = CACurrentMediaTime() }
            fire(batch)
        }

        if cursor >= events.count {
            // A recording can end mid-stroke: the crash typically happens
            // *inside* a handler of the final touch, killing the process
            // before its up/ended was persisted. Lift every finger still
            // down so that final gesture actually fires.
            if !fingers.isEmpty, let window {
                for (id, finger) in fingers {
                    pointer.touchEnded(at: finger.point, in: window, finger: id)
                    finger.touch.crs_move(to: finger.point)
                    finger.touch.crs_setPhase(.ended)
                }
                CRSTouchSender.send(orderedTouches())
                fingers = [:]
            }
            reportStats(elapsed: elapsed)
            finish()
        }
    }

    /// The touches of every finger down, in a stable order.
    private func orderedTouches() -> [UITouch] {
        fingers.keys.sorted().compactMap { fingers[$0]?.touch }
    }

    /// Delivers one touch event: the fingers in `changed` carry their new
    /// phase, every other finger still down is reported as stationary — the
    /// shape of a real multi-finger event.
    private func send(changed: Set<Int>) {
        for (id, finger) in fingers where !changed.contains(id) {
            finger.touch.crs_setPhase(.stationary)
        }
        CRSTouchSender.send(orderedTouches())
    }

    private func fire(_ batch: [ScheduledEvent]) {
        guard let window else { return }
        var changed = Set<Int>()
        var lifted: [Int] = []

        // The pointer is updated before each injection: what the overlay
        // shows is the touch that is about to be delivered.
        for e in batch {
            switch e.phase {
            case .began:
                // A began while this finger is still down means its ended was
                // never recorded — lift it before putting it down again.
                if let stale = fingers[e.finger] {
                    pointer.touchEnded(at: stale.point, in: window, finger: e.finger)
                    stale.touch.crs_setPhase(.ended)
                    send(changed: [e.finger])
                    fingers[e.finger] = nil
                }
                guard let touch = UITouch.crs_touchBeginning(at: e.point, window: window) else { continue }
                fingers[e.finger] = Finger(touch: touch, point: e.point)
                pointer.touchBegan(at: e.point, in: window, finger: e.finger)
                changed.insert(e.finger)

            case .moved:
                guard let finger = fingers[e.finger] else { continue }
                pointer.touchMoved(to: e.point, in: window, finger: e.finger)
                finger.touch.crs_move(to: e.point)
                fingers[e.finger]?.point = e.point
                changed.insert(e.finger)

            case .ended:
                guard let finger = fingers[e.finger] else { continue }
                pointer.touchEnded(at: e.point, in: window, finger: e.finger)
                finger.touch.crs_move(to: e.point) // final position
                finger.touch.crs_setPhase(.ended)
                fingers[e.finger]?.point = e.point
                changed.insert(e.finger)
                lifted.append(e.finger)
            }
        }

        guard !changed.isEmpty else { return }
        send(changed: changed)
        lifted.forEach { fingers[$0] = nil }
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
        // Durations are measured from the first touch's due time, so they read
        // the same whether or not the timeline was pinned to the launch.
        let firstOffset = events.first?.offset ?? 0
        let expected = (events.last?.offset ?? 0) - firstOffset
        let actual = elapsed - firstOffset
        var summary = String(
            format: "CrashCam replay finished: %d events, expected %.3fs, actual %.3fs, end drift %+.1fms, max event lateness %.1fms",
            events.count, expected, actual, (actual - expected) * 1000, maxLateness * 1000
        )
        if alignedToLaunch, let launchReference, let firstFireTime {
            summary += String(format: ", first touch %.3fs after launch (recorded %.3fs)",
                              firstFireTime - launchReference, firstOffset)
        }
        print(summary)
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("replay_stats.txt")
        try? summary.write(to: url, atomically: true, encoding: .utf8)
    }
}

#endif

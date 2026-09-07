//
//  UserTapInfo.swift
//  CrashCam
//
//  Created by Metin Tarık Kiki on 28.12.2025.
//

import CoreGraphics
import Foundation

/// One recorded user-input event. Despite the name, the stream is a mix of
/// touch events, text-field/-view edits and screen changes (`kind`). The
/// persisted shape stays a `JSONEncoder`-encoded `[UserTapInfo]` array so the
/// Appium replay keeps reading one file; non-touch rows are simply rows with
/// another `kind`.
///
/// Since 2026-09-03 rows also carry *where* the input happened: `screen` (the
/// visible screen's name, see `ScreenTracker`) on every row, and on touch-down
/// rows the touched `element` (its class) plus its `elementId` (accessibility
/// identifier). Screen geometry (`screenSize`, `scale`) rides on the
/// session-start and screen-change rows so a viewer can draw the recording to
/// scale. All of these are optional and absent from older recordings.
public struct UserTapInfo: Codable {

    public enum Kind: Int, Codable {
        case touch = 0
        case textChange = 1
        case keyboardHide = 2
        /// The recording session started — written first in every session, at
        /// app launch. Its timestamp is what lets a replay fire the first touch
        /// at the same delay after launch as it was recorded.
        case sessionStart = 3
        /// The visible screen changed (a view controller appeared, or the app
        /// called `CrashCam.markScreen`). Carries `screen` and the current
        /// window geometry.
        case screenChange = 4
    }

    public enum Phase: Int, Codable {
        case began = 0
        case moved = 1
        case ended = 2
    }

    public let kind: Kind
    public let location: CGPoint
    public let timestamp: Date
    public let phase: Phase
    /// Character count of the active text field/view at the moment it changed.
    /// Only the *length* is ever recorded — never the typed text. `nil` for
    /// touch events.
    public let textLength: Int?

    /// Name of the screen visible when the event happened: the top-most view
    /// controller's class (a hosting controller reports its root SwiftUI view
    /// type), or the name the app set with `CrashCam.markScreen` /
    /// `crashCamScreenName`. `nil` when unknown.
    public let screen: String?
    /// Class of the touched element (touch-down rows only), e.g. `UIButton`
    /// or a custom cell class. Never its text or label.
    public let element: String?
    /// The touched element's `accessibilityIdentifier` (touch-down rows only),
    /// when the app set one. Identifiers are developer-assigned constants, so
    /// they are safe to record; accessibility *labels* are not recorded.
    public let elementId: String?
    /// Window size in points, on session-start and screen-change rows.
    public let screenSize: CGSize?
    /// Screen scale (points → pixels), on session-start and screen-change rows.
    public let scale: CGFloat?

    /// A touch event (down / drag / up).
    public init(
        location: CGPoint,
        timestamp: Date,
        phase: Phase,
        screen: String? = nil,
        element: String? = nil,
        elementId: String? = nil
    ) {
        self.kind = .touch
        self.location = location
        self.timestamp = timestamp
        self.phase = phase
        self.textLength = nil
        self.screen = screen
        self.element = element
        self.elementId = elementId
        self.screenSize = nil
        self.scale = nil
    }

    /// A text-field/-view edit. Records only the current length by design, so no
    /// user-entered text is ever persisted. `location` is the field's on-screen
    /// origin (informational); replay types into the focused element instead.
    public init(
        textChangeAt location: CGPoint,
        timestamp: Date,
        textLength: Int,
        screen: String? = nil
    ) {
        self.kind = .textChange
        self.location = location
        self.timestamp = timestamp
        self.phase = .began // unused for text events; kept for the array contract
        self.textLength = textLength
        self.screen = screen
        self.element = nil
        self.elementId = nil
        self.screenSize = nil
        self.scale = nil
    }

    /// The on-screen keyboard was dismissed. Carries only a timestamp; replay
    /// uses it to close the keyboard at the same point in the timeline.
    public init(keyboardHideAt timestamp: Date, screen: String? = nil) {
        self.kind = .keyboardHide
        self.location = .zero
        self.timestamp = timestamp
        self.phase = .began // unused for keyboard events; kept for the array contract
        self.textLength = nil
        self.screen = screen
        self.element = nil
        self.elementId = nil
        self.screenSize = nil
        self.scale = nil
    }

    /// The recording session started (the app launched, or an in-process
    /// replay reset the log). Carries a timestamp and, when known, the screen
    /// geometry. `phase` is `.ended` on purpose: the legacy Appium `replay.js`
    /// groups rows by phase alone and drops an `ended` with no open stroke, so
    /// this row is invisible to it instead of becoming a tap at the origin.
    public init(sessionStartAt timestamp: Date, screenSize: CGSize? = nil, scale: CGFloat? = nil) {
        self.kind = .sessionStart
        self.location = .zero
        self.timestamp = timestamp
        self.phase = .ended
        self.textLength = nil
        self.screen = nil
        self.element = nil
        self.elementId = nil
        self.screenSize = screenSize
        self.scale = scale
    }

    /// The visible screen changed. Same `phase` trick as the session-start row
    /// so the legacy Appium replay ignores it; the in-process replayer only
    /// consumes `.touch` rows anyway.
    public init(screenChangeTo screen: String, timestamp: Date, screenSize: CGSize?, scale: CGFloat?) {
        self.kind = .screenChange
        self.location = .zero
        self.timestamp = timestamp
        self.phase = .ended
        self.textLength = nil
        self.screen = screen
        self.element = nil
        self.elementId = nil
        self.screenSize = screenSize
        self.scale = scale
    }

    enum CodingKeys: String, CodingKey {
        case kind, location, timestamp, phase, textLength
        case screen, element, elementId, screenSize, scale
    }

    // Backward-compatible decoding: logs recorded before text tracking carry no
    // `kind`/`textLength`, and logs recorded before screen tracking carry none
    // of the screen/element fields — default them all, so old `crash_cam.txt`
    // files keep decoding (and replaying) as pure touch sequences.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .touch
        self.location = try c.decode(CGPoint.self, forKey: .location)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.phase = try c.decode(Phase.self, forKey: .phase)
        self.textLength = try c.decodeIfPresent(Int.self, forKey: .textLength)
        self.screen = try c.decodeIfPresent(String.self, forKey: .screen)
        self.element = try c.decodeIfPresent(String.self, forKey: .element)
        self.elementId = try c.decodeIfPresent(String.self, forKey: .elementId)
        self.screenSize = try c.decodeIfPresent(CGSize.self, forKey: .screenSize)
        self.scale = try c.decodeIfPresent(CGFloat.self, forKey: .scale)
    }

    // Explicit encoding so nil optionals are omitted rather than written as
    // null: rows without screen data keep exactly their pre-2026-09 shape.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(location, forKey: .location)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(textLength, forKey: .textLength)
        try c.encodeIfPresent(screen, forKey: .screen)
        try c.encodeIfPresent(element, forKey: .element)
        try c.encodeIfPresent(elementId, forKey: .elementId)
        try c.encodeIfPresent(screenSize, forKey: .screenSize)
        try c.encodeIfPresent(scale, forKey: .scale)
    }
}

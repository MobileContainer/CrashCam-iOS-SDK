//
//  UserTapInfo.swift
//  CrashCam
//
//  Created by Metin Tarık Kiki on 28.12.2025.
//

import CoreGraphics
import Foundation

/// One recorded user-input event. Despite the name, the stream is a mix of
/// touch events and text-field/-view edits (`kind`). The persisted shape stays
/// a `JSONEncoder`-encoded `[UserTapInfo]` array so the Appium replay keeps
/// reading one file; text edits are simply rows with `kind == .textChange`.
public struct UserTapInfo: Codable {

    public enum Kind: Int, Codable {
        case touch = 0
        case textChange = 1
        case keyboardHide = 2
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

    /// A touch event (down / drag / up).
    public init(
        location: CGPoint,
        timestamp: Date,
        phase: Phase
    ) {
        self.kind = .touch
        self.location = location
        self.timestamp = timestamp
        self.phase = phase
        self.textLength = nil
    }

    /// A text-field/-view edit. Records only the current length by design, so no
    /// user-entered text is ever persisted. `location` is the field's on-screen
    /// origin (informational); replay types into the focused element instead.
    public init(
        textChangeAt location: CGPoint,
        timestamp: Date,
        textLength: Int
    ) {
        self.kind = .textChange
        self.location = location
        self.timestamp = timestamp
        self.phase = .began // unused for text events; kept for the array contract
        self.textLength = textLength
    }

    /// The on-screen keyboard was dismissed. Carries only a timestamp; replay
    /// uses it to close the keyboard at the same point in the timeline.
    public init(keyboardHideAt timestamp: Date) {
        self.kind = .keyboardHide
        self.location = .zero
        self.timestamp = timestamp
        self.phase = .began // unused for keyboard events; kept for the array contract
        self.textLength = nil
    }

    enum CodingKeys: String, CodingKey {
        case kind, location, timestamp, phase, textLength
    }

    // Backward-compatible decoding: logs recorded before text tracking carry no
    // `kind`/`textLength`, so default them — old `crash_cam.txt` files keep
    // decoding (and replaying) as pure touch sequences.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .touch
        self.location = try c.decode(CGPoint.self, forKey: .location)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.phase = try c.decode(Phase.self, forKey: .phase)
        self.textLength = try c.decodeIfPresent(Int.self, forKey: .textLength)
    }
}

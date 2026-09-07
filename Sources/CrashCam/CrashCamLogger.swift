//
//  CrashCamLogger.swift
//  CrashCam
//
//  Created by Metin Tarık Kiki on 28.12.2025.
//

import CoreGraphics
import Foundation

@MainActor
public final class CrashCamLogger {

    public static let shared = CrashCamLogger()

    // Each event is appended to this file the instant it happens, so the data
    // is already durably on disk *before* any crash. We deliberately do NOT
    // serialize inside the crash signal handler: JSONEncoder and UserDefaults
    // are not async-signal-safe and frequently fail there (malloc/lock deadlock,
    // or the deferred cfprefsd flush never landing when the process is dying),
    // which is why saving previously only worked "sometimes".
    private let eventsFileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("crashcam_events.jsonl")

    // Final file consumed by the Appium replay: a JSON array of UserTapInfo,
    // encoded exactly as before so replay.js is unaffected. Public so the
    // crash uploader can attach it without duplicating the path.
    public let replayFileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("crash_cam.txt")

    private let encoder = JSONEncoder()
    private let queue = DispatchQueue(label: "CrashCamLogger.write")
    private var handle: FileHandle?

    /// While true, `add(_:)` drops events entirely. Set by the in-process
    /// replayer: synthetic touches flow back through
    /// `TrackingWindow.sendEvent` and would otherwise be re-recorded.
    public var isPaused = false

    private init() {}

    // MARK: - Recording

    // Events are held on disk only — deliberately not mirrored in memory. An
    // in-memory copy would grow unbounded for the life of a session (it is
    // only cleared at launch) and buys nothing: every reader, including
    // exportForReplay(), goes through the JSONL file, which is the copy that
    // survives the crash.
    public func add(_ info: UserTapInfo) {
        guard !isPaused else { return }
        append(info)
    }

    /// The write itself, unconditional — the session-start marker must land
    /// even while recording is paused (a replay resetting the log).
    private func append(_ info: UserTapInfo) {
        // Synchronous append on the calling (main/touch) thread. The event must
        // be on disk before a potential crash on the very next instruction; a
        // background/async flush could lose the last — often crash-causing —
        // events. The write is tiny (~80 bytes), which is acceptable for a
        // record-and-replay debugging tool.
        queue.sync {
            ensureHandle()
            guard let handle else { return }
            guard var line = try? encoder.encode(info) else { return }
            line.append(0x0A) // '\n' — one JSON object per line (JSONL)
            do {
                try handle.write(contentsOf: line)
            } catch {
                print("CrashCam: failed to append event: \(error)")
            }
        }
    }

    private func ensureHandle() {
        guard handle == nil else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: eventsFileURL.path) {
            fm.createFile(atPath: eventsFileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: eventsFileURL)
        try? handle?.seekToEnd()
    }

    // MARK: - Session lifecycle

    /// Call once at launch, *after* exporting any pending-crash data. Truncates
    /// the rolling event log so the new session is recorded from a clean slate,
    /// then writes the session-start marker as its first row: a replay of this
    /// session can then fire its first touch at the same delay after launch
    /// as the user did.
    public func startNewSession(screenSize: CGSize? = nil, scale: CGFloat? = nil) {
        queue.sync {
            try? handle?.close()
            handle = nil
            try? Data().write(to: eventsFileURL, options: .atomic)
        }
        append(UserTapInfo(sessionStartAt: Date(), screenSize: screenSize, scale: scale))
    }

    /// Reads the durable event log written by the crashed session and writes
    /// the JSON array the Appium replay expects. Returns true if the session
    /// recorded any input; a log holding nothing but the session-start marker
    /// (a crash reproduced by an in-process replay, which pauses recording)
    /// leaves the previous `crash_cam.txt` intact and returns false.
    @discardableResult
    public func exportForReplay() -> Bool {
        // The crashed process's writes went through write(2) into the kernel
        // buffer cache, so they survive process death and are readable here
        // without any action from the (now gone) crash handler.
        guard let data = try? Data(contentsOf: eventsFileURL),
              let text = String(data: data, encoding: .utf8)
        else { return false }

        let decoder = JSONDecoder()
        var events: [UserTapInfo] = []
        for line in text.split(separator: "\n") {
            let lineData = Data(line.utf8)
            guard !lineData.isEmpty else { continue }
            if let event = try? decoder.decode(UserTapInfo.self, from: lineData) {
                events.append(event)
            }
        }

        guard events.contains(where: { $0.kind != .sessionStart }) else {
            print("CrashCam: the crashed session recorded no input — keeping the previous replay file")
            return false
        }
        guard let arrayData = try? encoder.encode(events),
              let arrayText = String(data: arrayData, encoding: .utf8)
        else { return false }

        do {
            try arrayText.write(to: replayFileURL, atomically: true, encoding: .utf8)
            print("CrashCam: exported \(events.count) events to \(replayFileURL.path)")
            return true
        } catch {
            print("CrashCam: failed to write replay file: \(error)")
            return false
        }
    }
}

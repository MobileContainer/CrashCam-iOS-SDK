//
//  CrashCam.swift
//  CrashCam
//
//  Created by Metin Tarık Kiki on 28.12.2025.
//

import Foundation
import UIKit
import CrashReporter

/// Crash-capture orchestration facade. `bootstrap()` reproduces, verbatim, the
/// launch sequence that previously lived in the host app's `AppDelegate`:
/// install the (deliberately no-op) PLCrashReporter signal callback, redirect
/// stderr to disk, export any pending-crash taps for the Appium replay, surface
/// the previous crash report, then start a clean recording session and enable
/// the reporter. If `uploadEndpoint` is set, a detected crash is also POSTed
/// (report + taps + app/device metadata) to the crash-server dashboard.
@MainActor
public final class CrashCam {

    public static let shared = CrashCam()

    /// When non-nil, a detected pending crash is uploaded here as
    /// `multipart/form-data` (the `crash-server` `POST /api/crashes` contract).
    /// Leave nil to disable uploading; all other behavior is unchanged.
    public var uploadEndpoint: URL?

    /// Shared secret sent as `X-CrashCam-Token` with the upload. Required by a
    /// crash-server whose `CRASHCAM_UPLOAD_TOKEN` env var is set (the hosted
    /// deployment); leave nil for an open (local) server.
    public var uploadToken: String?

    private let crashReporter: PLCrashReporter? = PLCrashReporter(configuration: PLCrashReporterConfig.defaultConfiguration())
    private var crashFD = Int32(-1)
    private var crashFDPointer: UnsafeMutableRawPointer?

    /// Tail of the *previous* session's stderr, captured at bootstrap before
    /// this session's redirect truncates the file. Swift runtime failures
    /// ("Fatal error: Index out of range") print here and nowhere else — the
    /// crash report itself only records the SIGTRAP — so this is the only
    /// surviving source of a Crashlytics-style crash reason for them.
    private var previousSessionStderr = ""

    private static let lastCrashInfoKey = "lastCrashInfo"

    private init() {}

    /// Call once from `application(_:didFinishLaunchingWithOptions:)`. Pass
    /// `uploadEndpoint` to enable crash uploads (equivalent to setting the
    /// `uploadEndpoint` property before calling), and `uploadToken` when that
    /// server requires one. Defaults preserve the prior no-upload behavior.
    public func bootstrap(uploadEndpoint: URL? = nil, uploadToken: String? = nil) {
        if let uploadEndpoint {
            self.uploadEndpoint = uploadEndpoint
        }
        if let uploadToken {
            self.uploadToken = uploadToken
        }

        setupCrashCallbacks()
        previousSessionStderr = Self.tailOfFile(at: Self.stderrLogURL, maxBytes: 256 * 1024)
        redirectStderr()

        if crashReporter?.hasPendingCrashReport() == true {
            // Export the taps recorded by the crashed session BEFORE we start a
            // new (truncating) session. The events were appended to disk as they
            // happened, so they are guaranteed to be here regardless of how the
            // crash handler behaved. The return value tells us whether the taps
            // are fresh for *this* crash (false = zero taps recorded, so
            // crash_cam.txt is stale and must not be uploaded).
            let touchesAreFresh = CrashCamLogger.shared.exportForReplay()

            if let lastCrashInfo = UserDefaults.standard.string(forKey: Self.lastCrashInfoKey) {
                print(lastCrashInfo)
                printLastStderr()
                saveCrashInfo(lastCrashInfo)
            }

            handleCrashReport(touchesAreFresh: touchesAreFresh)
        }

        // Begin recording the new session from a clean event log.
        CrashCamLogger.shared.startNewSession()

        // Start recording text-field/-view edits (length only) into the same
        // event stream. Touches are captured by TrackingWindow; this covers the
        // keyboard side.
        TextInputTracker.shared.start()

        crashReporter?.enable()

        #if DEBUG
        scheduleLaunchReplayIfRequested()
        #endif
    }

    #if DEBUG
    /// Launch-argument replay triggers (Xcode: Scheme ▸ Run ▸ Arguments, or
    /// `simctl launch <bundle-id> …`). Either
    ///
    ///     -CrashCamReplayOnLaunch                 replay this app's own last crash
    ///     -CrashCamReplayFile <path/to/file.json> replay a chosen recording
    ///
    /// The file form takes precedence and does not need the plain flag; it
    /// accepts any `[UserTapInfo]` JSON — notably a `touches.json` downloaded
    /// from the crash-server dashboard, which is the same format as
    /// `crash_cam.txt`. On the Simulator a plain host path works as-is (the
    /// Simulator shares the Mac's filesystem); on a device the file has to be
    /// somewhere the app can actually read.
    private func scheduleLaunchReplayIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let chosenFile = Self.launchArgumentValue("-CrashCamReplayFile", in: arguments)
            .map { raw -> URL in
                // `~` expands against *this app's container*, not the Mac's home
                // directory — an easy trap when the file was downloaded to
                // ~/Downloads on the host, so say so instead of just reporting
                // a missing file.
                let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                if raw.hasPrefix("~"), !FileManager.default.fileExists(atPath: url.path) {
                    print("""
                        CrashCam replay: '~' resolves to this app's container, not the Mac's \
                        home directory, so \(url.path) does not exist. Pass an absolute host \
                        path (e.g. /Users/you/Downloads/touches.json) to replay a file from the Mac.
                        """)
                }
                return url
            }

        guard chosenFile != nil || arguments.contains("-CrashCamReplayOnLaunch") else { return }

        // The delay lets the UI reach its settled post-launch state (the
        // recording's own t0 is its first touch, so the replay timeline is
        // unaffected by when it starts).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let chosenFile {
                self.replay(fileURL: chosenFile)
            } else {
                self.replayLastSession()
            }
        }
    }

    /// Value following `flag` in the argument list, or nil when the flag is
    /// absent or trailing.
    private static func launchArgumentValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.index(after: index) < arguments.endIndex
        else { return nil }
        let value = arguments[arguments.index(after: index)]
        return value.isEmpty ? nil : value
    }
    #endif

    #if DEBUG
    /// Replays the last crashed session's touch sequence (`crash_cam.txt`)
    /// inside the running app via synthetic UITouch injection. The app must be
    /// at its fresh post-launch state — which is exactly where every recording
    /// starts, since the event log is truncated at bootstrap. Touches only for
    /// now; text/keyboard events are skipped.
    ///
    /// Returns false when there is no decodable recording or no window.
    @discardableResult
    public func replayLastSession(speed: Double = 1.0,
                                  completion: (() -> Void)? = nil) -> Bool {
        replay(fileURL: CrashCamLogger.shared.replayFileURL,
               speed: speed,
               completion: completion)
    }

    /// Replays any recording file — a `[UserTapInfo]` JSON array, which is
    /// both this app's `crash_cam.txt` and the `touches.json` served by the
    /// crash-server dashboard (`GET /api/crashes/:id/touches`), so a crash
    /// recorded on another device can be reproduced here.
    ///
    /// The starting UI state still has to match the recording's: replay the
    /// same app version, from a fresh launch, as every recording begins at
    /// launch. Returns false when the file cannot be read or decoded, when it
    /// holds no events, or when there is no window to replay into.
    @discardableResult
    public func replay(fileURL: URL,
                       speed: Double = 1.0,
                       completion: (() -> Void)? = nil) -> Bool {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            print("CrashCam replay: cannot read \(fileURL.path): \(error.localizedDescription)")
            return false
        }

        let recording: [UserTapInfo]
        do {
            recording = try JSONDecoder().decode([UserTapInfo].self, from: data)
        } catch {
            print("CrashCam replay: \(fileURL.lastPathComponent) is not a [UserTapInfo] array: \(error)")
            return false
        }

        guard !recording.isEmpty else {
            print("CrashCam replay: \(fileURL.lastPathComponent) contains no events")
            return false
        }
        print("CrashCam replay: loaded \(recording.count) event(s) from \(fileURL.path)")

        // The replay pointer overlay is a window too (still fading out if a
        // replay just ended) — never replay into it.
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !($0 is ReplayPointerWindow) }
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else {
            print("CrashCam replay: no window to replay into")
            return false
        }

        // Truncate the live event log before injecting. If the replay
        // reproduces the crash, the next launch then sees an empty log,
        // exportForReplay() returns false, and the original recording in
        // crash_cam.txt survives for another replay — instead of being
        // overwritten by the handful of taps that started this one.
        CrashCamLogger.shared.startNewSession()

        TouchReplayer.shared.replay(recording, in: window, speed: speed, completion: completion)
        return true
    }
    #endif

    public func saveCrashInfo(_ info: String) {
        let fileURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crash_report.txt")

        do {
            try info.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to save crash info: \(error)")
        }

        //UserDefaults.standard.set(nil, forKey: Self.lastCrashInfoKey)
    }

    private func setupCrashCallbacks() {
        crashFD = open("/tmp/crash_marker.txt", O_WRONLY | O_CREAT, 0o644)
        withUnsafeMutableBytes(of: &crashFD) { crashFDPointer in
            var callbacks = PLCrashReporterCallbacks(
                version: 0,
                context: crashFDPointer.baseAddress
            ) { info, uap, context in
                // Intentionally a no-op. This runs inside an async signal
                // handler where only async-signal-safe calls are allowed —
                // JSONEncoder/UserDefaults/Foundation here deadlock or get
                // dropped, which is why saving used to be unreliable. Tap data
                // is already durably on disk (appended as each event happened),
                // so nothing needs to be done at crash time.
                //
                // If you ever need a crash marker, only async-signal-safe calls
                // such as write(2) to a pre-opened fd are permitted here.
            }

            crashReporter?.setCrash(&callbacks)
        }
    }

    private static var stderrLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stderr.log")
    }

    /// Last `maxBytes` of a file as UTF-8 (from a character boundary), or ""
    /// when the file is missing/unreadable. Capped so a chatty session cannot
    /// balloon memory.
    private static func tailOfFile(at url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else { return "" }
        // Lossy decode: a mid-character cut at the seek offset must not throw
        // the whole tail away.
        return String(decoding: data, as: UTF8.self)
    }

    /// Truncating ("w") on purpose: the log holds exactly the current session,
    /// so on the next launch its content is attributable to *this* run — the
    /// previous session's tail has already been captured by `bootstrap()`.
    public func redirectStderr() {
        freopen(Self.stderrLogURL.path, "w+", stderr)
        setbuf(stderr, nil) // disable buffering
    }

    public func printLastStderr() {
        if previousSessionStderr.isEmpty {
            print("Crash log is empty.")
        } else {
            print("Crash log contents:\n\(previousSessionStderr)")
        }
    }

    /// Crashlytics-style one-line crash reason, best source first:
    /// an uncaught NSException's name+reason from the report; else the last
    /// Swift runtime failure line from the crashed session's stderr (these
    /// carry file:line, e.g. "ViewController.swift:87: Fatal error: Index out
    /// of range"); else the plain signal name.
    private func crashReason(for report: PLCrashReport) -> String {
        if report.hasExceptionInfo, let exception = report.exceptionInfo {
            let name = (exception.exceptionName as String?) ?? "NSException"
            let reason = (exception.exceptionReason as String?) ?? ""
            return reason.isEmpty ? name : "\(name): \(reason)"
        }

        let markers = [
            "Fatal error",
            "Precondition failed",
            "Assertion failed",
            "Terminating app due to uncaught exception",
        ]
        if let line = previousSessionStderr
            .split(separator: "\n")
            .last(where: { line in markers.contains { line.contains($0) } }) {
            return line.trimmingCharacters(in: .whitespaces)
        }

        if let signal = report.signalInfo, let name = signal.name as String? {
            let code = (signal.code as String?).map { " (\($0))" } ?? ""
            return "Signal \(name)\(code)"
        }
        return ""
    }

    private func handleCrashReport(touchesAreFresh: Bool) {
        do {
            if let data = try crashReporter?.loadPendingCrashReportDataAndReturnError() {

                // Read marker file
                if let markerData = try? String(contentsOfFile: "/tmp/crash_marker.txt") {
                    print("Crash marker: \(markerData)")
                } else {
                    print("No marker data")
                }

                let crashReport = try PLCrashReport(data: data)

                // Crash report text
                let crashInfo = PLCrashReportTextFormatter.stringValue(for: crashReport,
                                                                       with: PLCrashReportTextFormatiOS)

                // Save combined report
                UserDefaults.standard.set(crashInfo, forKey: Self.lastCrashInfoKey)

                crashReporter?.purgePendingCrashReport()

                // Upload *this* crash's report together with *this* crash's
                // taps. Both are in hand right here (crashInfo just computed;
                // crash_cam.txt just written by exportForReplay), so we sidestep
                // the one-launch lag of the UserDefaults `lastCrashInfo` path.
                if let uploadEndpoint, let crashInfo {
                    let meta = appDeviceMetadata()
                    CrashReportUploader.upload(
                        endpoint: uploadEndpoint,
                        token: uploadToken,
                        appName: meta.appName,
                        bundleId: meta.bundleId,
                        appVersion: meta.appVersion,
                        deviceName: meta.deviceName,
                        deviceVersion: meta.deviceVersion,
                        crashReason: crashReason(for: crashReport),
                        reportText: crashInfo,
                        touchesFileURL: touchesAreFresh ? CrashCamLogger.shared.replayFileURL : nil
                    )
                }
            }
        } catch {
            print("Error handling crash report: \(error)")
        }
    }

    private func appDeviceMetadata() -> (
        appName: String,
        bundleId: String,
        appVersion: String,
        deviceName: String,
        deviceVersion: String
    ) {
        let info = Bundle.main.infoDictionary
        let appName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "Unknown"
        let shortVersion = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let device = UIDevice.current
        return (
            appName: appName,
            bundleId: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: "\(shortVersion) (\(build))",
            deviceName: device.name,
            deviceVersion: "\(device.systemName) \(device.systemVersion)"
        )
    }
}

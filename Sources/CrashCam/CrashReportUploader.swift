//
//  CrashReportUploader.swift
//  CrashCam
//
//  Created by Metin Tarık Kiki on 28.12.2025.
//

import Foundation

/// Fire-and-forget multipart uploader for a crash. Deliberately *not*
/// `@MainActor`-isolated and takes only `Sendable` value inputs, so it can run
/// off the main thread without hopping back to `CrashCam`'s isolation. The
/// field/file names match the `crash-server` API contract:
/// `POST /api/crashes` — fields `appName`, `bundleId`, `appVersion`,
/// `deviceName`, `deviceVersion`, `crashReason`; files `crashReport`,
/// `touches`.
enum CrashReportUploader {

    static func upload(
        endpoint: URL,
        token: String? = nil,
        appName: String,
        bundleId: String = "",
        appVersion: String,
        deviceName: String,
        deviceVersion: String,
        crashReason: String,
        reportText: String,
        touchesFileURL: URL?
    ) {
        let boundary = "CrashCam-\(UUID().uuidString)"
        let crlf = "\r\n"
        var body = Data()

        func appendString(_ string: String) {
            // ASCII-only multipart framing — encoding cannot fail.
            body.append(Data(string.utf8))
        }

        func appendField(_ name: String, _ value: String) {
            appendString("--\(boundary)\(crlf)")
            appendString("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
            appendString(value)
            appendString(crlf)
        }

        func appendFile(_ name: String, filename: String, mime: String, data: Data) {
            appendString("--\(boundary)\(crlf)")
            appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\(crlf)")
            appendString("Content-Type: \(mime)\(crlf)\(crlf)")
            body.append(data)
            appendString(crlf)
        }

        appendField("appName", appName)
        appendField("bundleId", bundleId)
        appendField("appVersion", appVersion)
        appendField("deviceName", deviceName)
        appendField("deviceVersion", deviceVersion)
        appendField("crashReason", crashReason)

        appendFile(
            "crashReport",
            filename: "crash_report.txt",
            mime: "text/plain",
            data: Data(reportText.utf8)
        )

        if let touchesFileURL,
           let touchesData = try? Data(contentsOf: touchesFileURL) {
            appendFile(
                "touches",
                filename: "touches.json",
                mime: "application/json",
                data: touchesData
            )
        }

        appendString("--\(boundary)--\(crlf)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-CrashCam-Token")
        }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                print("CrashCam: crash upload failed: \(error)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("CrashCam: crash upload finished (HTTP \(status))")
        }.resume()
    }
}

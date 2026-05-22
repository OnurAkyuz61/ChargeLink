//
//  LogitechKirosBatteryClient.swift
//  ChargeLink
//
//  Reads battery + charging from Logi Options+ / G HUB Kiros WebSocket (when running).
//  Same API as LGSTrayBattery — ws://127.0.0.1 with Sec-WebSocket-Protocol: json
//

import Foundation

/// Battery state from Logitech Kiros agent (Options+ / G HUB).
enum LogitechKirosBatteryClient {
    private static let candidatePorts = [9010, 57318, 57321, 57324, 5984, 19090]
    private static let collectTimeoutSeconds: TimeInterval = 2.0

    /// Product name (normalized) → battery info; empty if Kiros agent is not reachable.
    static func fetchBatteryInfo() async -> [String: LogitechBatteryInfo] {
        for port in candidatePorts {
            if let map = await fetch(fromPort: port), !map.isEmpty {
                BluetoothDebug.log("Kiros: got \(map.count) device(s) from port \(port)")
                return map
            }
        }
        BluetoothDebug.log("Kiros: no agent WebSocket (is Logi Options+ running?)")
        return [:]
    }

    // MARK: - WebSocket session

    private static func fetch(fromPort port: Int) async -> [String: LogitechBatteryInfo]? {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { return nil }

        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: url)
        request.setValue("json", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("file://", forHTTPHeaderField: "Origin")

        let task = session.webSocketTask(with: request)
        task.resume()

        defer { task.cancel(with: .goingAway, reason: nil) }

        do {
            try await waitForConnection(task: task, timeout: 1.5)
        } catch {
            BluetoothDebug.log("Kiros: port \(port) connect failed — \(error.localizedDescription)")
            return nil
        }

        var deviceNamesByID: [String: String] = [:]
        var results: [String: LogitechBatteryInfo] = [:]

        let subscribePaths = [
            "/battery/state/changed",
            "/devices/state/changed",
            "/devices/state/activated",
        ]

        for path in subscribePaths {
            try? await sendJSON(
                task: task,
                ["msgId": UUID().uuidString, "verb": "SUBSCRIBE", "path": path]
            )
        }

        let deadline = Date().addingTimeInterval(collectTimeoutSeconds)
        while Date() < deadline {
            do {
                let message = try await receiveMessage(task: task, timeout: 0.4)
                ingestMessage(message, deviceNamesByID: &deviceNamesByID, results: &results)
                // Kiros cancels SUBSCRIBE after each message — renew it.
                for path in subscribePaths {
                    try? await sendJSON(
                        task: task,
                        ["msgId": UUID().uuidString, "verb": "SUBSCRIBE", "path": path]
                    )
                }
            } catch {
                break
            }
        }

        return results.isEmpty ? nil : results
    }

    private static func waitForConnection(task: URLSessionWebSocketTask, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var finished = false

            func finish(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            task.sendPing { error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(()))
                }
            }

            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(.failure(KirosError.timeout))
            }
        }
    }

    private static func sendJSON(task: URLSessionWebSocketTask, _ object: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }

    private static func receiveMessage(task: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw KirosError.timeout
            }
            group.addTask {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    return text
                case .data(let data):
                    return String(data: data, encoding: .utf8) ?? ""
                @unknown default:
                    return ""
                }
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - JSON parsing

    private static func ingestMessage(
        _ text: String,
        deviceNamesByID: inout [String: String],
        results: inout [String: LogitechBatteryInfo]
    ) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let payload = root["payload"] as? [String: Any] {
            mergePayload(payload, deviceNamesByID: &deviceNamesByID, results: &results)
        }
        if let devices = root["devices"] as? [[String: Any]] {
            for device in devices {
                mergePayload(device, deviceNamesByID: &deviceNamesByID, results: &results)
            }
        }
        mergePayload(root, deviceNamesByID: &deviceNamesByID, results: &results)
    }

    private static func mergePayload(
        _ payload: [String: Any],
        deviceNamesByID: inout [String: String],
        results: inout [String: LogitechBatteryInfo]
    ) {
        if let deviceID = payload["deviceId"] as? String ?? payload["id"] as? String {
            if let name = deviceDisplayName(from: payload) {
                deviceNamesByID[deviceID] = name
            }
        }

        let charging = extractCharging(from: payload)
        let percent = extractPercent(from: payload)
        guard charging != nil || percent != nil else {
            // Recurse into nested device objects
            for value in payload.values {
                if let nested = value as? [String: Any] {
                    mergePayload(nested, deviceNamesByID: &deviceNamesByID, results: &results)
                } else if let array = value as? [[String: Any]] {
                    for item in array {
                        mergePayload(item, deviceNamesByID: &deviceNamesByID, results: &results)
                    }
                }
            }
            return
        }

        let name = deviceDisplayName(from: payload)
            ?? (payload["deviceId"] as? String).flatMap { deviceNamesByID[$0] }
        guard let name, !name.isEmpty else { return }

        let key = DeviceNameMatcher.normalize(name)
        let isCharging = charging ?? false
        let info = LogitechBatteryInfo(percent: percent, isCharging: isCharging)
        if let existing = results[key] {
            results[key] = LogitechBatteryInfo(
                percent: info.percent ?? existing.percent,
                isCharging: existing.isCharging || info.isCharging
            )
        } else {
            results[key] = info
        }
    }

    private static func deviceDisplayName(from payload: [String: Any]) -> String? {
        let keys = [
            "extendedDisplayName",
            "displayName",
            "deviceName",
            "name",
            "productName",
            "friendlyName",
        ]
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func extractCharging(from payload: [String: Any]) -> Bool? {
        let keys = ["charging", "isCharging", "is_charging", "recharging"]
        for key in keys {
            if let value = payload[key] as? Bool { return value }
            if let value = payload[key] as? Int { return value != 0 }
            if let value = payload[key] as? String {
                let lower = value.lowercased()
                if lower == "true" || lower == "yes" || lower.contains("charg") { return true }
                if lower == "false" || lower == "no" || lower == "discharg" { return false }
            }
        }
        if let status = payload["batteryStatus"] as? String ?? payload["status"] as? String {
            let lower = status.lowercased()
            if lower.contains("charg") || lower == "full" || lower.contains("recharg") { return true }
            if lower.contains("discharg") { return false }
        }
        return nil
    }

    private static func extractPercent(from payload: [String: Any]) -> Int? {
        let keys = ["percentage", "percent", "batteryPercent", "level", "chargeLevel"]
        for key in keys {
            if let value = payload[key] as? Int, (0...100).contains(value) { return value }
            if let value = payload[key] as? Double {
                let intVal = Int(value.rounded())
                if (0...100).contains(intVal) { return intVal }
            }
        }
        return nil
    }

    private enum KirosError: Error {
        case timeout
    }
}

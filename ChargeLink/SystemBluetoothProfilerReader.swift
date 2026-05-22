//
//  SystemBluetoothProfilerReader.swift
//  ChargeLink
//
//  Reads the same Bluetooth device list macOS shows in System Settings
//  via `system_profiler SPBluetoothDataType` (public, sandbox-safe).
//

import Foundation

/// Battery data parsed from System Settings / system_profiler Bluetooth report.
struct ProfilerBatteryInfo: Sendable {
    let percent: Int?
    let detailText: String?
    let address: String?

    func asBatteryReading(source: String = "system_profiler") -> BatteryReading? {
        guard percent != nil || !(detailText?.isEmpty ?? true) else { return nil }
        return BatteryReading(percent: percent, detailText: detailText, source: source)
    }
}

enum SystemBluetoothProfilerReader {
    private static let profilerPath = "/usr/sbin/system_profiler"

    /// Product name (normalized) or Bluetooth address → battery info.
    static func fetchConnectedDeviceBatteries() -> [String: ProfilerBatteryInfo] {
        guard let output = runProfiler() else {
            BluetoothDebug.log("system_profiler: no output")
            return [:]
        }
        return parse(output)
    }

    private static func runProfiler() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: profilerPath)
        process.arguments = ["SPBluetoothDataType"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            BluetoothDebug.log("system_profiler failed: \(error.localizedDescription)")
            return nil
        }

        guard process.terminationStatus == 0 else {
            BluetoothDebug.log("system_profiler exit \(process.terminationStatus)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    static func parse(_ text: String) -> [String: ProfilerBatteryInfo] {
        guard let connectedRange = text.range(of: "Connected:") else { return [:] }
        var section = String(text[connectedRange.upperBound...])
        if let notConnected = section.range(of: "Not Connected:") {
            section = String(section[..<notConnected.lowerBound])
        }

        var result: [String: ProfilerBatteryInfo] = [:]
        var currentName: String?
        var currentAddress: String?
        var left: Int?
        var right: Int?
        var caseBatt: Int?
        var single: Int?

        func flushDevice() {
            guard let currentName else { return }
            let info = buildInfo(
                name: currentName,
                address: currentAddress,
                left: left,
                right: right,
                caseBatt: caseBatt,
                single: single
            )
            let nameKey = DeviceNameMatcher.normalize(currentName)
            result[nameKey] = info
            if let currentAddress {
                let addrKey = BluetoothAddressNormalizer.normalize(currentAddress)
                if !addrKey.isEmpty {
                    result[addrKey] = info
                }
            }
            BluetoothDebug.log("system_profiler: \(currentName) → \(info.detailText ?? info.percent.map { "\($0)%" } ?? "—")")
            currentName = nil
            currentAddress = nil
            left = nil
            right = nil
            caseBatt = nil
            single = nil
        }

        for line in section.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let name = deviceName(from: line) {
                flushDevice()
                currentName = name
                continue
            }

            if let address = propertyValue(prefix: "Address:", in: trimmed) {
                currentAddress = address
                continue
            }

            if let value = batteryValue(prefix: "Left Battery Level:", in: trimmed) {
                left = value
            } else if let value = batteryValue(prefix: "Right Battery Level:", in: trimmed) {
                right = value
            } else if let value = batteryValue(prefix: "Case Battery Level:", in: trimmed) {
                caseBatt = value
            } else if let value = batteryValue(prefix: "Battery Level:", in: trimmed) {
                single = value
            }
        }
        flushDevice()

        return result
    }

    private static func deviceName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(":"), !trimmed.contains("=") else { return nil }
        let name = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let lower = name.lowercased()
        if lower == "connected" || lower.hasPrefix("address") { return nil }
        return name
    }

    private static func propertyValue(prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    private static func batteryValue(prefix: String, in line: String) -> Int? {
        guard let raw = propertyValue(prefix: prefix, in: line) else { return nil }
        let digits = raw.filter(\.isNumber)
        guard let value = Int(digits), (1...100).contains(value) else { return nil }
        return value
    }

    private static func buildInfo(
        name: String,
        address: String?,
        left: Int?,
        right: Int?,
        caseBatt: Int?,
        single: Int?
    ) -> ProfilerBatteryInfo {
        var parts: [String] = []
        if let left { parts.append("L: \(left)%") }
        if let right { parts.append("R: \(right)%") }
        if let caseBatt { parts.append("C: \(caseBatt)%") }

        if !parts.isEmpty {
            let buds = [left, right].compactMap { $0 }
            let primary = buds.min() ?? caseBatt ?? single
            return ProfilerBatteryInfo(
                percent: primary,
                detailText: parts.joined(separator: " "),
                address: address
            )
        }

        if let single {
            return ProfilerBatteryInfo(percent: single, detailText: "\(single)%", address: address)
        }

        return ProfilerBatteryInfo(percent: nil, detailText: nil, address: address)
    }
}

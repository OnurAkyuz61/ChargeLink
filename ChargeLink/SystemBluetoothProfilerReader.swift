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
    let isCharging: Bool

    func asBatteryReading(source: String = "system_profiler") -> BatteryReading? {
        guard percent != nil || !(detailText?.isEmpty ?? true) else { return nil }
        return BatteryReading(percent: percent, detailText: detailText, isCharging: isCharging, source: source)
    }
}

enum SystemBluetoothProfilerReader {
    private static let profilerPath = "/usr/sbin/system_profiler"

    private static let connectedSectionMarkers = ["Connected:", "Bağlı:", "Bagli:"]
    private static let disconnectedSectionMarkers = ["Not Connected:", "Bağlı Değil:", "Bagli Degil:"]

    private static let addressPrefixes = ["Address:", "Adres:"]
    private static let batteryPrefixes: [(key: String, part: BatteryPart)] = [
        ("Left Battery Level:", .left),
        ("Sol Pil Seviyesi:", .left),
        ("Right Battery Level:", .right),
        ("Sağ Pil Seviyesi:", .right),
        ("Case Battery Level:", .caseBattery),
        ("Kutu Pil Seviyesi:", .caseBattery),
        ("Battery Level:", .single),
        ("Pil Seviyesi:", .single),
    ]

    private enum BatteryPart {
        case left, right, caseBattery, single
    }

    /// Product name (normalized) or Bluetooth address → battery info.
    static func fetchConnectedDeviceBatteries() -> [String: ProfilerBatteryInfo] {
        guard let output = runProfiler() else {
            BluetoothDebug.log("system_profiler: no output (sandbox may block Process — check entitlements)")
            return [:]
        }
        BluetoothDebug.log("system_profiler: received \(output.count) characters")
        let parsed = parse(output)
        if parsed.isEmpty {
            BluetoothDebug.log("system_profiler: parse produced 0 devices — preview:\n\(output.prefix(400))")
        }
        return parsed
    }

    private static func runProfiler() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: profilerPath)
        process.arguments = ["SPBluetoothDataType"]
        process.environment = [
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/sbin:/usr/bin:/bin:/sbin",
        ]

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

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            BluetoothDebug.log("system_profiler exit \(process.terminationStatus), empty stdout")
            return nil
        }
        if process.terminationStatus != 0 {
            BluetoothDebug.log("system_profiler exit \(process.terminationStatus) (using stdout anyway)")
        }
        return text
    }

    static func parse(_ text: String) -> [String: ProfilerBatteryInfo] {
        guard let connectedMarker = connectedSectionMarkers.first(where: { text.contains($0) }),
              let connectedRange = text.range(of: connectedMarker) else {
            BluetoothDebug.log("system_profiler: no connected section marker found")
            return [:]
        }
        var section = String(text[connectedRange.upperBound...])
        if let endMarker = disconnectedSectionMarkers.compactMap({ section.range(of: $0) }).first {
            section = String(section[..<endMarker.lowerBound])
        }

        var result: [String: ProfilerBatteryInfo] = [:]
        var currentName: String?
        var currentAddress: String?
        var left: Int?
        var right: Int?
        var caseBatt: Int?
        var single: Int?
        var isCharging = false

        func flushDevice() {
            guard let deviceName = currentName else { return }
            let info = buildInfo(
                name: deviceName,
                address: currentAddress,
                left: left,
                right: right,
                caseBatt: caseBatt,
                single: single,
                isCharging: isCharging
            )
            let nameKey = DeviceNameMatcher.normalize(deviceName)
            result[nameKey] = info
            if let shortName = parentheticalDeviceName(from: deviceName) {
                result[DeviceNameMatcher.normalize(shortName)] = info
            }
            if let currentAddress {
                let addrKey = BluetoothAddressNormalizer.normalize(currentAddress)
                if !addrKey.isEmpty {
                    result[addrKey] = info
                }
            }
            BluetoothDebug.log("system_profiler: \(deviceName) → \(info.detailText ?? info.percent.map { "\($0)%" } ?? "—")")
            currentName = nil
            currentAddress = nil
            left = nil
            right = nil
            caseBatt = nil
            single = nil
            isCharging = false
        }

        for line in section.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let name = deviceName(from: line) {
                flushDevice()
                currentName = name
                continue
            }

            if let address = firstPropertyValue(in: trimmed, prefixes: addressPrefixes) {
                currentAddress = address
                continue
            }

            if let (value, part) = firstBatteryValue(in: trimmed) {
                switch part {
                case .left: left = value
                case .right: right = value
                case .caseBattery: caseBatt = value
                case .single: single = value
                }
                continue
            }

            if parseChargingFlag(in: trimmed) {
                isCharging = true
            }
        }
        flushDevice()

        return result
    }

    /// e.g. `Onur (AirPods Pro)` → `AirPods Pro` for IOBluetooth name matching.
    private static func parentheticalDeviceName(from name: String) -> String? {
        guard let open = name.lastIndex(of: "("), let close = name.lastIndex(of: ")"), close > open else {
            return nil
        }
        let inner = name[name.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : String(inner)
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

    private static func firstPropertyValue(in line: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            guard line.hasPrefix(prefix) else { continue }
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func firstBatteryValue(in line: String) -> (Int, BatteryPart)? {
        for entry in batteryPrefixes {
            guard line.hasPrefix(entry.key) else { continue }
            let raw = line.dropFirst(entry.key.count).trimmingCharacters(in: .whitespaces)
            let digits = raw.filter(\.isNumber)
            guard let value = Int(digits), (1...100).contains(value) else { continue }
            return (value, entry.part)
        }
        return nil
    }

    private static func parseChargingFlag(in line: String) -> Bool {
        let lower = line.lowercased()
        let prefixes = ["charging:", "is charging:", "şarj:", "power source:"]
        for prefix in prefixes {
            guard lower.hasPrefix(prefix) else { continue }
            let value = lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if value.contains("yes") || value.contains("evet") || value.contains("ac") || value.contains("şarj") {
                return true
            }
        }
        return false
    }

    private static func buildInfo(
        name: String,
        address: String?,
        left: Int?,
        right: Int?,
        caseBatt: Int?,
        single: Int?,
        isCharging: Bool
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
                address: address,
                isCharging: isCharging
            )
        }

        if let single {
            return ProfilerBatteryInfo(
                percent: single,
                detailText: "\(single)%",
                address: address,
                isCharging: isCharging
            )
        }

        return ProfilerBatteryInfo(percent: nil, detailText: nil, address: address, isCharging: isCharging)
    }
}

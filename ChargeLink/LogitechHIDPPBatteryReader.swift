//
//  LogitechHIDPPBatteryReader.swift
//  ChargeLink
//
//  Reads Logitech HID++ 2.0 battery features (unified / voltage) via IOHID feature reports.
//  Public API only — same approach as Solaar / Linux hid-logitech-hidpp.
//

import Foundation
import IOKit
import IOKit.hid

struct LogitechBatteryInfo: Equatable {
    let percent: Int?
    let isCharging: Bool
}

enum LogitechHIDPPBatteryReader {
    private static let logitechVendorID = 0x046D
    private static let hidppShortReportID: UInt8 = 0x10
    private static let hidppLongReportID: UInt8 = 0x11

    private static let featureSetID: UInt16 = 0x0001
    private static let featureUnifiedBattery: UInt16 = 0x1004
    private static let featureBatteryVoltage: UInt16 = 0x1001
    private static let featureBatteryStatus: UInt16 = 0x1000

    /// Product name (normalized) → charging / percent from HID++.
    static func allBatteryInfo() -> [String: LogitechBatteryInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            BluetoothDebug.log("HID++: manager open failed")
            return [:]
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return [:]
        }

        var map: [String: LogitechBatteryInfo] = [:]
        for device in deviceSet {
            guard let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String,
                  !product.isEmpty else { continue }
            guard vendorID(of: device) == logitechVendorID else { continue }

            guard let info = queryBattery(on: device) else { continue }
            let key = DeviceNameMatcher.normalize(product)
            if let existing = map[key] {
                map[key] = LogitechBatteryInfo(
                    percent: info.percent ?? existing.percent,
                    isCharging: existing.isCharging || info.isCharging
                )
            } else {
                map[key] = info
            }
            let chargeLabel = info.isCharging ? " charging" : ""
            let pct = info.percent.map { "\($0)%" } ?? "?"
            BluetoothDebug.log("HID++: \(product) → \(pct)\(chargeLabel)")
        }
        return map
    }

    // MARK: - HID++ session

    private static func queryBattery(on device: IOHIDDevice) -> LogitechBatteryInfo? {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let reportLength = max(
            Int(IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0),
            Int(IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? 0),
            7
        )

        for devIndex: UInt8 in [0x01, 0xFF] {
            guard ping(device: device, devIndex: devIndex, reportLength: reportLength) else { continue }
            guard let features = discoverFeatures(device: device, devIndex: devIndex, reportLength: reportLength) else {
                continue
            }

            if let idx = features[featureUnifiedBattery],
               let info = readUnifiedBattery(device: device, devIndex: devIndex, featureIndex: idx, reportLength: reportLength) {
                return info
            }
            if let idx = features[featureBatteryVoltage],
               let info = readBatteryVoltage(device: device, devIndex: devIndex, featureIndex: idx, reportLength: reportLength) {
                return info
            }
            if let idx = features[featureBatteryStatus],
               let info = readBatteryStatus(device: device, devIndex: devIndex, featureIndex: idx, reportLength: reportLength) {
                return info
            }
        }
        return nil
    }

    private static func ping(device: IOHIDDevice, devIndex: UInt8, reportLength: Int) -> Bool {
        let swID = UInt8.random(in: 0...0x0F)
        let requestID: UInt16 = 0x0010 | UInt16(swID)
        guard let reply = sendRequest(
            device: device,
            devIndex: devIndex,
            requestID: requestID,
            params: [0, 0, swID],
            reportLength: reportLength
        ), reply.count >= 4 else {
            return false
        }
        return true
    }

    private static func discoverFeatures(
        device: IOHIDDevice,
        devIndex: UInt8,
        reportLength: Int
    ) -> [UInt16: UInt8]? {
        guard let rootReply = sendRequest(
            device: device,
            devIndex: devIndex,
            requestID: 0x0000,
            params: [UInt8(featureSetID >> 8), UInt8(featureSetID & 0xFF)],
            reportLength: reportLength
        ), let featureSetIndex = rootReply.first, featureSetIndex > 0 else {
            return nil
        }

        guard let countReply = sendRequest(
            device: device,
            devIndex: devIndex,
            requestID: UInt16(featureSetIndex) << 8,
            params: [],
            reportLength: reportLength
        ), let rawCount = countReply.first else {
            return nil
        }

        let count = Int(rawCount) + 1
        var map: [UInt16: UInt8] = [:]

        for index in 0..<count {
            let requestID = (UInt16(featureSetIndex) << 8) | 0x10
            guard let reply = sendRequest(
                device: device,
                devIndex: devIndex,
                requestID: requestID,
                params: [index],
                reportLength: reportLength
            ), reply.count >= 2 else { continue }

            let featureID = UInt16(reply[0]) << 8 | UInt16(reply[1])
            map[featureID] = index
        }
        return map.isEmpty ? nil : map
    }

    private static func readUnifiedBattery(
        device: IOHIDDevice,
        devIndex: UInt8,
        featureIndex: UInt8,
        reportLength: Int
    ) -> LogitechBatteryInfo? {
        let requestID = (UInt16(featureIndex) << 8) | 0x10
        guard let reply = sendRequest(
            device: device,
            devIndex: devIndex,
            requestID: requestID,
            params: [],
            reportLength: reportLength
        ), reply.count >= 3 else {
            return nil
        }

        let percent = Int(reply[0])
        let statusByte = reply[2]
        let charging = isChargingStatus(statusByte)
        let normalizedPercent = (1...100).contains(percent) ? percent : nil
        return LogitechBatteryInfo(percent: normalizedPercent, isCharging: charging)
    }

    private static func readBatteryVoltage(
        device: IOHIDDevice,
        devIndex: UInt8,
        featureIndex: UInt8,
        reportLength: Int
    ) -> LogitechBatteryInfo? {
        let requestID = (UInt16(featureIndex) << 8) | 0x00
        guard let reply = sendRequest(
            device: device,
            devIndex: devIndex,
            requestID: requestID,
            params: [],
            reportLength: reportLength
        ), reply.count >= 3 else {
            return nil
        }

        let flags = reply[2]
        let charging = (flags & 0x80) != 0
        return LogitechBatteryInfo(percent: nil, isCharging: charging)
    }

    private static func readBatteryStatus(
        device: IOHIDDevice,
        devIndex: UInt8,
        featureIndex: UInt8,
        reportLength: Int
    ) -> LogitechBatteryInfo? {
        let requestID = (UInt16(featureIndex) << 8) | 0x00
        guard let reply = sendRequest(
            device: device,
            devIndex: devIndex,
            requestID: requestID,
            params: [],
            reportLength: reportLength
        ), reply.count >= 3 else {
            return nil
        }

        let percent = Int(reply[0])
        let statusByte = reply[2]
        let charging = isChargingStatus(statusByte)
        let normalizedPercent = (1...100).contains(percent) ? percent : nil
        return LogitechBatteryInfo(percent: normalizedPercent, isCharging: charging)
    }

    /// Logitech `BatteryStatus` flags (HID++ 2.0).
    private static func isChargingStatus(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x01, 0x02, 0x03, 0x04: // recharging, almost full, full, slow recharge
            return true
        default:
            return false
        }
    }

    private static func sendRequest(
        device: IOHIDDevice,
        devIndex: UInt8,
        requestID: UInt16,
        params: [UInt8],
        reportLength: Int
    ) -> [UInt8]? {
        var payload: [UInt8] = [
            UInt8(requestID >> 8),
            UInt8(requestID & 0xFF),
        ]
        payload.append(contentsOf: params)
        while payload.count < 5 { payload.append(0) }

        let useLong = reportLength >= 20
        var report = [UInt8](repeating: 0, count: reportLength)
        report[0] = useLong ? hidppLongReportID : hidppShortReportID
        report[1] = devIndex
        for i in 0..<min(payload.count, report.count - 2) {
            report[i + 2] = payload[i]
        }

        let reportID = CFIndex(report[0])
        var sent = report
        let setStatus = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeFeature,
            reportID,
            &sent,
            sent.count
        )
        guard setStatus == kIOReturnSuccess else { return nil }

        var received = [UInt8](repeating: 0, count: reportLength)
        var length = received.count
        var getStatus = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeInput,
            reportID,
            &received,
            &length
        )
        if getStatus != kIOReturnSuccess {
            length = received.count
            getStatus = IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                reportID,
                &received,
                &length
            )
        }
        guard getStatus == kIOReturnSuccess, length >= 4 else { return nil }

        // Reply payload starts at index 2 (after report ID + device index).
        return Array(received[2..<min(length, received.count)])
    }

    private static func vendorID(of device: IOHIDDevice) -> Int? {
        if let n = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int {
            return n
        }
        if let n = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber {
            return n.intValue
        }
        return nil
    }
}

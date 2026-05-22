//
//  LogitechHIDPPBatteryReader.swift
//  ChargeLink
//
//  Reads Logitech HID++ 2.0 battery features via IOHID (AppleUserHIDEventService path).
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

    private static var softwareID: UInt8 = 0

    /// Product name (normalized) → battery info from HID++.
    static func allBatteryInfo() -> [String: LogitechBatteryInfo] {
        var map: [String: LogitechBatteryInfo] = [:]

        for (product, device) in logitechHIDDevices() {
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
            let chargeLabel = info.isCharging ? " ⚡" : ""
            let pct = info.percent.map { "\($0)%" } ?? "?"
            BluetoothDebug.log("HID++: \(product) → \(pct)\(chargeLabel)")
        }

        if map.isEmpty {
            BluetoothDebug.log("HID++: no battery feature replies (sandbox or device busy)")
        }
        return map
    }

    // MARK: - Device discovery (same path as IOHIDBatteryReader)

    private static func logitechHIDDevices() -> [(String, IOHIDDevice)] {
        var pairs: [(String, IOHIDDevice)] = []

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, ["VendorID": logitechVendorID] as CFDictionary)
        if IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
           let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in deviceSet {
                guard let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String,
                      !product.isEmpty else { continue }
                pairs.append((product, device))
            }
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let matching = IOServiceMatching("AppleUserHIDEventService") else { return pairs }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return pairs
        }
        defer { IOObjectRelease(iterator) }

        var seenProducts = Set(pairs.map { DeviceNameMatcher.normalize($0.0) })
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let product = IORegistryEntryCreateCFProperty(
                entry, "Product" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String, !product.isEmpty else { continue }

            let key = DeviceNameMatcher.normalize(product)
            guard !seenProducts.contains(key) else { continue }
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, entry) else { continue }
            seenProducts.insert(key)
            pairs.append((product, device))
        }
        return pairs
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
            20
        )

        for devIndex: UInt8 in [0x01, 0xFF] {
            guard ping(device: device, devIndex: devIndex, reportLength: reportLength) else { continue }
            guard let features = discoverFeatures(device: device, devIndex: devIndex, reportLength: reportLength) else {
                continue
            }

            if let idx = features[featureUnifiedBattery],
               let info = readUnifiedBattery(device: device, devIndex: devIndex, featureIndex: idx, reportLength: reportLength),
               info.isCharging || info.percent != nil {
                return info
            }
            if let idx = features[featureBatteryVoltage],
               let info = readBatteryVoltage(device: device, devIndex: devIndex, featureIndex: idx, reportLength: reportLength),
               info.isCharging {
                return info
            }
            if let idx = features[featureBatteryStatus],
               let info = readBatteryStatus(device: device, devIndex: devIndex, featureIndex: idx, reportLength: reportLength),
               info.isCharging || info.percent != nil {
                return info
            }
        }
        return nil
    }

    private static func nextSoftwareID() -> UInt8 {
        softwareID = (softwareID + 1) & 0x0F
        return softwareID
    }

    private static func wrapRequestID(_ base: UInt16, devIndex: UInt8) -> UInt16 {
        guard devIndex != 0xFF, base < 0x8000 else { return base }
        return (base & 0xFFF0) | UInt16(nextSoftwareID())
    }

    private static func ping(device: IOHIDDevice, devIndex: UInt8, reportLength: Int) -> Bool {
        let swID = nextSoftwareID()
        let requestID = wrapRequestID(0x0010 | UInt16(swID), devIndex: devIndex)
        guard let reply = sendRequest(
            device: device,
            devIndex: devIndex,
            requestID: requestID,
            params: [0, 0, swID],
            reportLength: reportLength
        ), reply.count >= 2 else {
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
            requestID: wrapRequestID(0x0000, devIndex: devIndex),
            params: [UInt8(featureSetID >> 8), UInt8(featureSetID & 0xFF)],
            reportLength: reportLength
        ), let featureSetIndex = rootReply.first, featureSetIndex > 0 else {
            return nil
        }

        guard let countReply = sendRequest(
            device: device,
            devIndex: devIndex,
            requestID: wrapRequestID(UInt16(featureSetIndex) << 8, devIndex: devIndex),
            params: [],
            reportLength: reportLength
        ), let rawCount = countReply.first else {
            return nil
        }

        let count = Int(rawCount) + 1
        var map: [UInt16: UInt8] = [:]

        for index in 0..<count {
            guard index <= Int(UInt8.max) else { continue }
            let featureIndex = UInt8(index)
            let requestID = wrapRequestID((UInt16(featureSetIndex) << 8) | 0x10, devIndex: devIndex)
            guard let reply = sendRequest(
                device: device,
                devIndex: devIndex,
                requestID: requestID,
                params: [featureIndex],
                reportLength: reportLength
            ), reply.count >= 2 else { continue }

            let featureID = UInt16(reply[0]) << 8 | UInt16(reply[1])
            map[featureID] = featureIndex
        }
        return map.isEmpty ? nil : map
    }

    private static func readUnifiedBattery(
        device: IOHIDDevice,
        devIndex: UInt8,
        featureIndex: UInt8,
        reportLength: Int
    ) -> LogitechBatteryInfo? {
        let requestID = wrapRequestID((UInt16(featureIndex) << 8) | 0x10, devIndex: devIndex)
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
        let requestID = wrapRequestID((UInt16(featureIndex) << 8) | 0x00, devIndex: devIndex)
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
        let requestID = wrapRequestID((UInt16(featureIndex) << 8) | 0x00, devIndex: devIndex)
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

    /// HID++ `BatteryStatus` — 0 = discharging, 1–4 = charging variants.
    private static func isChargingStatus(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x00, 0x05, 0x06, 0x07:
            return false
        case 0x01, 0x02, 0x03, 0x04:
            return true
        default:
            return byte != 0
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
        let sent = report

        let setTypes: [IOHIDReportType] = [kIOHIDReportTypeFeature, kIOHIDReportTypeOutput]
        var setOK = false
        for type in setTypes {
            var copy = sent
            if IOHIDDeviceSetReport(device, type, reportID, &copy, copy.count) == kIOReturnSuccess {
                setOK = true
                break
            }
        }
        guard setOK else { return nil }

        let received = [UInt8](repeating: 0, count: reportLength)
        let getTypeGroups: [[IOHIDReportType]] = [
            [kIOHIDReportTypeInput, kIOHIDReportTypeFeature],
            [kIOHIDReportTypeFeature, kIOHIDReportTypeInput],
        ]
        for getTypes in getTypeGroups {
            var length = received.count
            var copy = received
            for type in getTypes {
                length = copy.count
                if IOHIDDeviceGetReport(device, type, reportID, &copy, &length) == kIOReturnSuccess,
                   length >= 4,
                   copy[0] == report[0] {
                    return Array(copy[2..<min(length, copy.count)])
                }
            }
        }
        return nil
    }
}

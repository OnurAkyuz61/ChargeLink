//
//  IOHIDBatteryReader.swift
//  ChargeLink
//
//  Reads Bluetooth peripheral battery via IOHID (live element values) and
//  Apple HID event services in IORegistry — required for Logitech BLE and AirPods.
//

import Foundation
import IOKit
import IOKit.hid

// MARK: - IOHID live battery reader

enum IOHIDBatteryReader {
    /// HID usage pages / usages for battery reporting (public IOHIDUsageTables.h values).
    private enum HIDBatteryUsage {
        static let pageGenericDeviceControls = UInt32(kHIDPage_GenericDeviceControls)
        static let pageBatterySystem = UInt32(kHIDPage_BatterySystem)
        static let genDevControlsBatteryStrength = UInt32(kHIDUsage_GenDevControls_BatteryStrength)
        static let bsRemainingCapacity = UInt32(kHIDUsage_BS_RemainingCapacity)
    }

    private static let hidPropertyBatteryKeys = [
        "BatteryPercent",
        "BatteryLevel",
        "CurrentCapacity",
        "MaxCapacity",
        "AppleDeviceBatteryLevel",
    ]
    /// Logitech BLE devices expose battery on vendor usage page 65347 (0xFF43).
    private static let logitechVendorPage: UInt32 = 65347
    private static let logitechBatteryUsage: UInt32 = 514

    private static let batteryUsageMatchers: [(UInt32, UInt32?)] = [
        (logitechVendorPage, logitechBatteryUsage),
        (logitechVendorPage, nil),
        (HIDBatteryUsage.pageGenericDeviceControls, HIDBatteryUsage.genDevControlsBatteryStrength),
        (HIDBatteryUsage.pageBatterySystem, HIDBatteryUsage.bsRemainingCapacity),
        (HIDBatteryUsage.pageBatterySystem, nil),
        (0xFF07, nil),
        (0xFF43, nil),
    ]

    /// Scans every HID device and returns product name → battery % (for merge with IOBluetooth list).
    static func allProductBatteries() -> [String: Int] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            BluetoothDebug.log("IOHID snapshot: manager open failed")
            return [:]
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return [:]
        }

        var map: [String: Int] = [:]
        for device in deviceSet {
            guard let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String,
                  !product.isEmpty else { continue }
            guard let percent = readBatteryFromDevice(device) else { continue }
            let key = DeviceNameMatcher.normalize(product)
            map[key] = Swift.max(map[key] ?? 0, percent)
            BluetoothDebug.log("IOHID snapshot: \(product) → \(percent)%")
        }
        return map
    }

    /// Reads battery via IOHIDDevice created from an `AppleUserHIDEventService` registry entry.
    static func batteryPercent(ioService: io_service_t) -> Int? {
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, ioService) else {
            return nil
        }
        return readBatteryFromDevice(device)
    }

    static func batteriesFromUserHIDEventServices() -> [String: Int] {
        guard let matching = IOServiceMatching("AppleUserHIDEventService") else { return [:] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var map: [String: Int] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let product = IORegistryEntryCreateCFProperty(
                entry,
                "Product" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String, !product.isEmpty else { continue }

            guard let percent = batteryPercent(ioService: entry) else { continue }
            let key = DeviceNameMatcher.normalize(product)
            map[key] = Swift.max(map[key] ?? 0, percent)
            BluetoothDebug.log("HID event service: \(product) → \(percent)%")
        }
        return map
    }

    static func batteryPercent(productName: String) -> Int? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        IOHIDManagerSetDeviceMatching(manager, nil)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            BluetoothDebug.log("  IOHIDManagerOpen failed")
            return nil
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return nil
        }

        let target = productName.lowercased()
        var bestPercent: Int?

        for device in deviceSet {
            guard let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String else {
                continue
            }
            guard productNameMatches(product, target: target) else { continue }

            BluetoothDebug.log("  IOHID device match: \(product)")

            if let percent = readBatteryFromDevice(device) {
                bestPercent = max(bestPercent ?? 0, percent)
            }
        }

        return bestPercent
    }

    private static func readBatteryFromDevice(_ device: IOHIDDevice) -> Int? {
        if let fromProperties = readBatteryFromHIDProperties(device) {
            return fromProperties
        }

        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return batteryFromElementMetadata(device)
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        for (page, usage) in batteryUsageMatchers {
            if let percent = readMatchingElements(device: device, usagePage: page, usage: usage) {
                return percent
            }
        }
        if let percent = scanAllInputElements(device: device) {
            return percent
        }
        return batteryFromElementMetadata(device)
    }

    private static func batteryFromElementMetadata(_ device: IOHIDDevice) -> Int? {
        guard let elements = IOHIDDeviceGetProperty(device, kIOHIDElementKey as CFString) else {
            return nil
        }
        return parseElementsProperty(elements, device: device)
    }

    /// Last resort: any input element on a vendor/battery page with a 0–100 logical range.
    private static func scanAllInputElements(device: IOHIDDevice) -> Int? {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? Set<IOHIDElement> else {
            return nil
        }
        var best: Int?
        for element in elements {
            let page = IOHIDElementGetUsagePage(element)
            let isCandidate = page == logitechVendorPage
                || page == Int(kHIDPage_BatterySystem)
                || page == Int(HIDBatteryUsage.pageGenericDeviceControls)
                || page == 0xFF07
            guard isCandidate else { continue }
            if let percent = readElementValue(device: device, element: element) {
                best = Swift.max(best ?? 0, percent)
            }
        }
        return best
    }

    private static func readBatteryFromHIDProperties(_ device: IOHIDDevice) -> Int? {
        var current: Int?
        var maxCap: Int?

        for key in hidPropertyBatteryKeys {
            guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { continue }
            if key == "CurrentCapacity", let parsed = BatteryValueNormalizer.extractInt(from: value) {
                current = parsed
            } else if key == "MaxCapacity", let parsed = BatteryValueNormalizer.extractInt(from: value) {
                maxCap = parsed
            } else if let percent = BatteryValueNormalizer.primaryPercent(from: value, key: key) {
                BluetoothDebug.log("    IOHID property \(key) → \(percent)%")
                return percent
            }
        }

        if let current, let maxCap, maxCap > 0 {
            let percent = Int((Double(current) / Double(maxCap) * 100).rounded())
            if (1...100).contains(percent) {
                BluetoothDebug.log("    IOHID CurrentCapacity/MaxCapacity → \(percent)%")
                return percent
            }
        }
        return nil
    }

    private static func readMatchingElements(
        device: IOHIDDevice,
        usagePage: UInt32,
        usage: UInt32?
    ) -> Int? {
        var match: [String: Any] = [kIOHIDElementUsagePageKey as String: usagePage]
        if let usage {
            match[kIOHIDElementUsageKey as String] = usage
        }

        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            match as CFDictionary,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? Set<IOHIDElement> else {
            return nil
        }

        var best: Int?
        for element in elements {
            if let percent = readElementValue(device: device, element: element) {
                BluetoothDebug.log("    IOHID page=\(usagePage) usage=\(usage ?? 0) → \(percent)%")
                best = max(best ?? 0, percent)
            }
        }
        return best
    }

    private static func readElementValue(device: IOHIDDevice, element: IOHIDElement) -> Int? {
        let hidValueOut = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { hidValueOut.deallocate() }

        // kIOHIDDeviceGetValueWithUpdate = 0x00020000 (force device report)
        let forceUpdate: UInt32 = 0x0002_0000
        let status = IOHIDDeviceGetValueWithOptions(device, element, hidValueOut, forceUpdate)
        if status != kIOReturnSuccess {
            guard IOHIDDeviceGetValue(device, element, hidValueOut) == kIOReturnSuccess else {
                return nil
            }
        }
        let value = hidValueOut.pointee.takeRetainedValue()

        let intValue = IOHIDValueGetIntegerValue(value)
        let logicalMin = IOHIDElementGetLogicalMin(element)
        let logicalMax = IOHIDElementGetLogicalMax(element)

        if logicalMax > logicalMin {
            let range = Double(logicalMax - logicalMin)
            let scaled = ((Double(intValue - logicalMin) / range) * 100).rounded()
            let percent = Int(scaled)
            if (1...100).contains(percent) { return percent }
        }

        if (1...100).contains(intValue) { return Int(intValue) }
        if (1...9).contains(intValue) { return Swift.min(100, (Int(intValue) * 100) / 9) }

        let scaled = IOHIDValueGetScaledValue(value, IOHIDValueScaleType(kIOHIDValueScaleTypeCalibrated))
        if scaled.isFinite {
            let percent = Int(scaled.rounded())
            if (1...100).contains(percent) { return percent }
        }

        return nil
    }

    private static func parseElementsProperty(_ elements: Any, device: IOHIDDevice) -> Int? {
        guard let rootElements = elements as? [[String: Any]] else { return nil }

        var best: Int?
        for flattened in flattenElements(rootElements) {
            guard let page = intValue(flattened["UsagePage"]),
                  let usage = intValue(flattened["Usage"]) else { continue }

            let isBatteryPage = (
                page == Int(HIDBatteryUsage.pageGenericDeviceControls)
                    && usage == Int(HIDBatteryUsage.genDevControlsBatteryStrength)
            ) || page == Int(HIDBatteryUsage.pageBatterySystem)
                || page == Int(logitechVendorPage) || page == 0xFF07 || page == 0xFF43

            guard isBatteryPage else { continue }

            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
                if let cookie = intValue(flattened["ElementCookie"]),
                   let element = findElementByCookie(cookie, in: device) {
                    if let percent = readElementValue(device: device, element: element) {
                        best = max(best ?? 0, percent)
                    }
                }
            }

            if let elementMax = intValue(flattened["Max"]), (1...100).contains(elementMax),
               let type = intValue(flattened["Type"]), type == 2 {
                best = Swift.max(best ?? 0, elementMax)
            }
        }
        return best
    }

    private static func findElementByCookie(_ cookie: Int, in device: IOHIDDevice) -> IOHIDElement? {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? Set<IOHIDElement> else {
            return nil
        }
        return elements.first { IOHIDElementGetCookie($0) == cookie }
    }

    private static func flattenElements(_ elements: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for element in elements {
            result.append(element)
            if let children = element["Elements"] as? [[String: Any]] {
                result.append(contentsOf: flattenElements(children))
            }
        }
        return result
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func productNameMatches(_ product: String, target: String) -> Bool {
        DeviceNameMatcher.matches(product, target: target)
    }
}

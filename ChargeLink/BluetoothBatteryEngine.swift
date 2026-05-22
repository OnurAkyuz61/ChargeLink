//
//  BluetoothBatteryEngine.swift
//  ChargeLink
//
//  Triple-source battery engine: CoreBluetooth GATT, IORegistry, IOHID.
//

import Foundation
import IOKit

// MARK: - Name matching

enum DeviceNameMatcher {
    static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ lhs: String, target rhs: String) -> Bool {
        let a = normalize(lhs)
        let b = normalize(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if a.contains(b) || b.contains(a) { return true }

        let aTokens = tokens(from: a)
        let bTokens = tokens(from: b)
        let overlap = aTokens.filter { token in
            bTokens.contains { $0.contains(token) || token.contains($0) }
        }
        return overlap.count >= max(1, min(aTokens.count, bTokens.count) / 2)
    }

    static func tokens(from name: String) -> [String] {
        normalize(name)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }
}

// MARK: - Engine

@MainActor
enum BluetoothBatteryEngine {
    private static var mergedReadingsByKey: [String: BatteryReading] = [:]

    private static let registryBatteryKeys = [
        "BatteryPercent",
        "BatteryLevel",
        "AppleDeviceBatteryLevel",
        "AppleRawDeviceBatteryLevel",
        "BatteryPercentLeft",
        "BatteryPercentRight",
        "BatteryPercentCase",
    ]

    private static let registryServiceClasses = [
        "AppleDeviceManagementHIDEventService",
        "AppleUserHIDEventService",
        "AppleBluetoothHIDDevice",
        "AppleHSBluetoothDevice",
        "IOBluetoothDevice",
        "IOHIDDevice",
        "IOHIDEventService",
    ]

    /// Refreshes all battery caches (BLE + IOHID snapshot + IORegistry snapshot).
    static func refreshBLECache() async {
        await refreshAllCaches()
    }

    static func refreshAllCaches() async {
        _ = await BLEBatteryScanner.shared.refresh()

        var merged: [String: BatteryReading] = [:]

        func store(_ key: String, _ reading: BatteryReading, replace: Bool = false) {
            let normalized = DeviceNameMatcher.normalize(key)
            guard !normalized.isEmpty else { return }
            if !replace, let existing = merged[normalized], existing.hasValue { return }
            merged[normalized] = reading
        }

        for (name, percent) in BLEBatteryScanner.shared.allReadings() {
            store(name, BatteryReading(percent: percent, detailText: "\(percent)%", source: "CoreBluetooth"))
        }
        for (name, percent) in IOHIDBatteryReader.allProductBatteries() {
            store(name, BatteryReading(percent: percent, detailText: "\(percent)%", source: "IOHID"))
        }
        for (name, percent) in IOHIDBatteryReader.batteriesFromUserHIDEventServices() {
            store(name, BatteryReading(percent: percent, detailText: "\(percent)%", source: "HID-EventService"))
        }
        for (name, percent) in IORegistryBatteryReader.allProductBatteries() {
            store(name, BatteryReading(percent: percent, detailText: "\(percent)%", source: "IORegistry"))
        }
        // Same source macOS Bluetooth settings uses for AirPods battery text.
        for (key, info) in SystemBluetoothProfilerReader.fetchConnectedDeviceBatteries() {
            if let reading = info.asBatteryReading() {
                store(key, reading, replace: true)
            }
        }

        mergedReadingsByKey = merged
        BluetoothDebug.log("Battery cache: \(merged.count) entries — \(merged.mapValues(\.displayText))")
    }

    /// Resolves battery for an IOBluetooth-connected device using all public subsystems.
    static func resolveBattery(name: String, address: String) -> BatteryReading {
        BluetoothDebug.log("BatteryEngine resolve '\(name)' @ \(address)")

        if let cached = batteryFromMergedCache(deviceName: name, address: address) {
            BluetoothDebug.log("  → \(cached.displayText) [cache]")
            return cached
        }

        var candidates: [PrioritizedBatteryReading] = []

        if let airPods = resolveAirPodsBattery(deviceName: name) {
            candidates.append(airPods.withPriority(0))
        }

        if let ble = resolveBLEBattery(deviceName: name) {
            candidates.append(ble.withPriority(1))
        }

        if let registry = resolveIORegistryBattery(name: name, address: address) {
            candidates.append(registry.withPriority(2))
        }

        if let hid = resolveIOHIDBattery(deviceName: name) {
            candidates.append(hid.withPriority(3))
        }

        if let best = PrioritizedBatteryReading.selectBest(from: candidates) {
            BluetoothDebug.log("  → \(best.displayText) [\(best.source)]")
            return best
        }

        BluetoothDebug.log("  → no battery data")
        return .unknown
    }

    private static func batteryFromMergedCache(deviceName: String, address: String) -> BatteryReading? {
        let nameKey = DeviceNameMatcher.normalize(deviceName)
        let addrKey = BluetoothAddressNormalizer.normalize(address)

        if let reading = mergedReadingsByKey[nameKey], reading.hasValue { return reading }
        if !addrKey.isEmpty, let reading = mergedReadingsByKey[addrKey], reading.hasValue { return reading }

        for (cachedKey, reading) in mergedReadingsByKey where reading.hasValue {
            if DeviceNameMatcher.matches(cachedKey, target: nameKey) {
                return reading
            }
        }
        return nil
    }

    // MARK: - CoreBluetooth

    private static func resolveBLEBattery(deviceName: String) -> BatteryReading? {
        guard let percent = BLEBatteryScanner.shared.percent(matchingDeviceName: deviceName) else {
            return nil
        }
        return BatteryReading(percent: percent, detailText: "\(percent)%", source: "CoreBluetooth-0x2A19")
    }

    // MARK: - IORegistry (Apple / AirPods)

    private static func resolveAirPodsBattery(deviceName: String) -> BatteryReading? {
        let lower = deviceName.lowercased()
        guard lower.contains("airpod")
            || lower.contains("airpods")
            || lower.contains("headphone")
            || lower.contains("beats")
            || lower.contains("powerbeats") else {
            return nil
        }

        if let components = scanRegistryForAirPodsComponents(matchingName: deviceName),
           let reading = components.asReading(source: "IORegistry-AirPods") {
            return reading
        }
        return nil
    }

    private static func resolveIORegistryBattery(name: String, address: String) -> BatteryReading? {
        if let components = scanRegistryForAirPodsComponents(matchingName: name),
           let reading = components.asReading(source: "IORegistry-components") {
            return reading
        }

        if let percent = IORegistryBatteryReader.batteryFromHIDEventServices(name: name, address: address) {
            return BatteryReading(percent: percent, detailText: "\(percent)%", source: "IORegistry-HIDEvent")
        }

        if let percent = IORegistryBatteryReader.batteryPercent(name: name, address: address) {
            return BatteryReading(percent: percent, detailText: "\(percent)%", source: "IORegistry-IOBluetooth")
        }

        if let percent = aggressiveRegistryScan(name: name, address: address) {
            return BatteryReading(percent: percent, detailText: "\(percent)%", source: "IORegistry-aggressive")
        }

        return nil
    }

    private static func scanRegistryForAirPodsComponents(matchingName name: String) -> AirPodsBatteryComponents? {
        var components = AirPodsBatteryComponents()

        for className in registryServiceClasses {
            enumerateRegistry(className: className) { entry in
                guard registryEntryMatchesName(entry, name: name) else { return }
                mergeAirPodsKeys(from: entry, into: &components)
                deepMergeAirPods(entry: entry, depth: 0, into: &components)
            }
        }

        return components.hasAnyValue ? components : nil
    }

    private static func mergeAirPodsKeys(from entry: io_registry_entry_t, into components: inout AirPodsBatteryComponents) {
        guard let props = copyRegistryProperties(entry) else { return }

        if let left = props["BatteryPercentLeft"].flatMap({ BatteryValueNormalizer.primaryPercent(from: $0, key: "BatteryPercentLeft") }) {
            components.left = left
        }
        if let right = props["BatteryPercentRight"].flatMap({ BatteryValueNormalizer.primaryPercent(from: $0, key: "BatteryPercentRight") }) {
            components.right = right
        }
        if let caseP = props["BatteryPercentCase"].flatMap({ BatteryValueNormalizer.primaryPercent(from: $0, key: "BatteryPercentCase") }) {
            components.casePercent = caseP
        }
        if let single = props["BatteryPercent"].flatMap({ BatteryValueNormalizer.primaryPercent(from: $0, key: "BatteryPercent") })
            ?? props["AppleRawDeviceBatteryLevel"].flatMap({ BatteryValueNormalizer.primaryPercent(from: $0, key: "AppleRawDeviceBatteryLevel") })
            ?? props["AppleDeviceBatteryLevel"].flatMap({ BatteryValueNormalizer.primaryPercent(from: $0, key: "AppleDeviceBatteryLevel") }) {
            components.single = single
        }

        if let dict = props["BatteryPercent"] as? [String: Any] {
            parseAirPodsDictionary(dict, into: &components)
        }
    }

    private static func parseAirPodsDictionary(_ dict: [String: Any], into components: inout AirPodsBatteryComponents) {
        for (key, value) in dict {
            let lower = key.lowercased()
            guard let percent = BatteryValueNormalizer.primaryPercent(from: value, key: "BatteryPercent") else { continue }
            if lower.contains("left") { components.left = percent }
            else if lower.contains("right") { components.right = percent }
            else if lower.contains("case") { components.casePercent = percent }
            else { components.single = percent }
        }
    }

    private static func deepMergeAirPods(entry: io_registry_entry_t, depth: Int, into components: inout AirPodsBatteryComponents) {
        guard depth <= 32 else { return }
        mergeAirPodsKeys(from: entry, into: &components)

        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(childIterator) }

        while case let child = IOIteratorNext(childIterator), child != 0 {
            deepMergeAirPods(entry: child, depth: depth + 1, into: &components)
            IOObjectRelease(child)
        }
    }

    private static func aggressiveRegistryScan(name: String, address: String) -> Int? {
        var best: Int?
        for className in registryServiceClasses {
            enumerateRegistry(className: className) { entry in
                guard registryEntryMatchesDevice(entry, name: name, address: address) else { return }
                if let percent = readRegistryBatteryKeys(on: entry) {
                    best = max(best ?? 0, percent)
                }
                deepScanRegistryBattery(entry: entry, depth: 0, best: &best)
            }
        }
        return best
    }

    private static func readRegistryBatteryKeys(on entry: io_registry_entry_t) -> Int? {
        guard let props = copyRegistryProperties(entry) else { return nil }
        for key in registryBatteryKeys {
            guard let value = props[key] else { continue }
            if let percent = BatteryValueNormalizer.primaryPercent(from: value, key: key) {
                return percent
            }
        }
        for (key, value) in props where key.lowercased().contains("battery") {
            if let percent = BatteryValueNormalizer.primaryPercent(from: value, key: key) {
                return percent
            }
        }
        return nil
    }

    private static func deepScanRegistryBattery(entry: io_registry_entry_t, depth: Int, best: inout Int?) {
        guard depth <= 32 else { return }
        if let percent = readRegistryBatteryKeys(on: entry) {
            best = max(best ?? 0, percent)
        }
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(childIterator) }
        while case let child = IOIteratorNext(childIterator), child != 0 {
            deepScanRegistryBattery(entry: child, depth: depth + 1, best: &best)
            IOObjectRelease(child)
        }
    }

    // MARK: - IOHID

    private static func resolveIOHIDBattery(deviceName: String) -> BatteryReading? {
        guard let percent = IOHIDBatteryReader.batteryPercent(productName: deviceName) else {
            return nil
        }
        return BatteryReading(percent: percent, detailText: "\(percent)%", source: "IOHID")
    }

    // MARK: - Registry helpers

    private static func enumerateRegistry(className: String, handler: (io_registry_entry_t) -> Void) {
        guard let matching = IOServiceMatching(className) else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            handler(entry)
        }
    }

    private static func copyRegistryProperties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func registryEntryMatchesName(_ entry: io_registry_entry_t, name: String) -> Bool {
        guard let props = copyRegistryProperties(entry) else { return false }
        let keys = ["Product", "ProductName", "IOName", "name", "ModelNumber"]
        for key in keys {
            if let value = props[key] as? String, DeviceNameMatcher.matches(value, target: name) {
                return true
            }
        }
        return false
    }

    private static func registryEntryMatchesDevice(_ entry: io_registry_entry_t, name: String, address: String) -> Bool {
        if registryEntryMatchesName(entry, name: name) { return true }
        guard let props = copyRegistryProperties(entry) else { return false }
        let normalized = BluetoothAddressNormalizer.normalize(address)
        guard !normalized.isEmpty else { return false }
        let addressKeys = ["DeviceAddress", "BluetoothAddress", "BD_ADDR", "address"]
        for key in addressKeys {
            if let value = props[key] as? String,
               BluetoothAddressNormalizer.normalize(value) == normalized {
                return true
            }
        }
        return false
    }
}

//
//  BluetoothManager.swift
//  ChargeLink
//

import Foundation
import IOBluetooth
import IOKit
import Observation

extension Notification.Name {
    static let chargeLinkDevicesDidUpdate = Notification.Name("ChargeLinkDevicesDidUpdate")
}

// MARK: - Debug

enum BluetoothDebug {
    static let isEnabled = true

    static func log(_ message: String) {
        guard isEnabled else { return }
        print("[ChargeLink] \(message)")
    }
}

// MARK: - IORegistry Battery Reader

/// Multi-strategy battery discovery via IORegistry (public IOKit APIs only).
enum IORegistryBatteryReader {
    static let maxSearchDepth = 32

    /// Keys checked on every registry node during deep traversal.
    static let batteryKeys: [String] = [
        "BatteryPercent",
        "BatteryLevel",
        "AppleDeviceBatteryLevel",
        "AppleRawDeviceBatteryLevel",
        "BatteryPercentLeft",
        "BatteryPercentRight",
        "BatteryPercentCase",
    ]

    private static let capacityKeys = (current: "CurrentCapacity", max: "MaxCapacity")

    private static let registryPlanes: [String] = [
        kIOServicePlane,
        kIOPowerPlane,
        kIODeviceTreePlane,
    ]

    private static let hidEventServiceClasses = [
        "AppleDeviceManagementHIDEventService",
        "AppleUserHIDEventService",
        "AppleBluetoothHIDDevice",
        "AppleHSBluetoothDevice",
        "IOHIDEventService",
    ]

    private static let hidServiceClasses = [
        "IOHIDDevice",
    ] + hidEventServiceClasses

    private static let addressPropertyKeys = [
        "DeviceAddress",
        "BluetoothAddress",
        "BD_ADDR",
        "address",
        "HIDAddress",
    ]

    private static let namePropertyKeys = [
        "Product",
        "ProductName",
        "IOName",
        "name",
        "USB Product Name",
    ]

    // MARK: - Public API

    /// Enumerates all HID event services and returns every product name → battery % pair found.
    static func allProductBatteries() -> [String: Int] {
        var map: [String: Int] = [:]

        for className in hidEventServiceClasses {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                guard let props = copyProperties(for: entry) else { continue }

                let productNames = namePropertyKeys.compactMap { props[$0] as? String }.filter { !$0.isEmpty }
                guard !productNames.isEmpty else { continue }

                var candidates: [BatteryCandidate] = []
                if let percent = readDirectBatteryProperty(on: entry) {
                    candidates.append(BatteryCandidate(percent: percent, priority: 0, source: "\(className).direct"))
                }
                collectBatteryPercentKeys(entry: entry, depth: 0, into: &candidates, path: className)

                guard let best = BatteryCandidate.selectBest(from: candidates) else { continue }
                for name in productNames {
                    let key = DeviceNameMatcher.normalize(name)
                    map[key] = Swift.max(map[key] ?? 0, best.percent)
                    BluetoothDebug.log("IORegistry snapshot: \(name) → \(best.percent)% [\(best.source)]")
                }
            }
        }

        return map
    }

    /// Scans Apple HID event driver services where macOS publishes `BatteryPercent` for BT peripherals.
    static func batteryFromHIDEventServices(name: String, address: String) -> Int? {
        var candidates: [BatteryCandidate] = []

        for className in hidEventServiceClasses {
            enumerateMatchingServices(className: className, name: name, address: address) { entry in
                if let percent = readDirectBatteryProperty(on: entry) {
                    candidates.append(
                        BatteryCandidate(percent: percent, priority: 0, source: "\(className).BatteryPercent")
                    )
                }
                collectBatteryPercentKeys(entry: entry, depth: 0, into: &candidates, path: className)
            }
        }

        return BatteryCandidate.selectBest(from: candidates)?.percent
    }

    static func batteryPercent(name: String, address: String) -> Int? {
        BluetoothDebug.log("IORegistry multi-strategy search for '\(name)' @ \(address)")

        var candidates: [BatteryCandidate] = []

        if let bluetoothRoot = findBluetoothDeviceEntry(address: address, name: name) {
            defer { IOObjectRelease(bluetoothRoot) }
            BluetoothDebug.log("  strategy: IOBluetoothDevice subtree")
            collectFromEntry(bluetoothRoot, depth: 0, into: &candidates, path: "IOBluetoothDevice")
        } else {
            BluetoothDebug.log("  strategy: no IOBluetoothDevice root (will try HID)")
        }

        collectFromHIDServices(name: name, address: address, into: &candidates)

        for className in hidServiceClasses where className != "IOHIDDevice" {
            collectFromServiceClass(className, name: name, address: address, into: &candidates)
        }

        guard let best = BatteryCandidate.selectBest(from: candidates) else {
            BluetoothDebug.log("  → no battery keys found")
            return nil
        }

        BluetoothDebug.log("  → battery \(best.percent)% via \(best.source)")
        return best.percent
    }

    // MARK: - Strategy 1: IOBluetoothDevice tree

    private static func findBluetoothDeviceEntry(address: String, name: String) -> io_registry_entry_t? {
        guard let matching = IOServiceMatching("IOBluetoothDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var nameFallback: io_registry_entry_t?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if entryMatches(entry: entry, address: address, name: name) {
                IOObjectRetain(entry)
                if let nameFallback { IOObjectRelease(nameFallback) }
                return entry
            }
            if nameFallback == nil, entryMatchesNameOnly(entry: entry, name: name) {
                IOObjectRetain(entry)
                nameFallback = entry
                continue
            }
            IOObjectRelease(entry)
        }
        return nameFallback
    }

    // MARK: - Strategy 2: IOHIDDevice (Logitech etc.)

    private static func collectFromHIDServices(
        name: String,
        address: String,
        into candidates: inout [BatteryCandidate]
    ) {
        BluetoothDebug.log("  strategy: IOHIDDevice services")
        enumerateMatchingServices(className: "IOHIDDevice", name: name, address: address, into: &candidates)
    }

    private static func collectFromServiceClass(
        _ className: String,
        name: String,
        address: String,
        into candidates: inout [BatteryCandidate]
    ) {
        enumerateMatchingServices(className: className, name: name, address: address, into: &candidates)
    }

    private static func enumerateMatchingServices(
        className: String,
        name: String,
        address: String,
        into candidates: inout [BatteryCandidate]
    ) {
        enumerateMatchingServices(className: className, name: name, address: address) { entry in
            collectFromEntry(entry, depth: 0, into: &candidates, path: className)
        }
    }

    private static func enumerateMatchingServices(
        className: String,
        name: String,
        address: String,
        handler: (io_registry_entry_t) -> Void
    ) {
        guard let matching = IOServiceMatching(className) else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard entryMatchesDevice(entry: entry, address: address, name: name) else { continue }
            handler(entry)
        }
    }

    private static func readDirectBatteryProperty(on entry: io_registry_entry_t) -> Int? {
        for key in batteryKeys {
            guard let value = copyProperty(key, from: entry) else { continue }
            if let percent = BatteryValueNormalizer.primaryPercent(from: value, key: key) {
                return percent
            }
        }
        return nil
    }

    private static func copyProperty(_ key: String, from entry: io_registry_entry_t) -> Any? {
        let cfKey = key as CFString
        guard let value = IORegistryEntryCreateCFProperty(entry, cfKey, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return value
    }

    /// Recursively finds any `BatteryPercent` / `BatteryLevel` key on child nodes.
    private static func collectBatteryPercentKeys(
        entry: io_registry_entry_t,
        depth: Int,
        into candidates: inout [BatteryCandidate],
        path: String
    ) {
        guard depth <= maxSearchDepth else { return }

        if let properties = copyProperties(for: entry) {
            for (key, value) in properties {
                let lower = key.lowercased()
                guard lower.contains("battery") else { continue }
                if let percent = BatteryValueNormalizer.primaryPercent(from: value, key: key)
                    ?? BatteryValueNormalizer.primaryPercent(from: value, key: "BatteryPercent") {
                    candidates.append(
                        BatteryCandidate(percent: percent, priority: 4, source: "\(path).\(key)")
                    )
                }
            }
        }

        for plane in registryPlanes {
            var childIterator: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(entry, plane, &childIterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(childIterator) }
            while case let child = IOIteratorNext(childIterator), child != 0 {
                collectBatteryPercentKeys(entry: child, depth: depth + 1, into: &candidates, path: path)
                IOObjectRelease(child)
            }
        }
    }

    // MARK: - Deep recursive traversal

    private static func collectFromEntry(
        _ entry: io_registry_entry_t,
        depth: Int,
        into candidates: inout [BatteryCandidate],
        path: String
    ) {
        guard depth <= maxSearchDepth else { return }

        if let properties = copyProperties(for: entry) {
            let className = registryEntryName(entry) ?? path
            if let found = BatteryValueNormalizer.extractBattery(from: properties) {
                candidates.append(
                    BatteryCandidate(percent: found.percent, priority: found.priority, source: "\(className).\(found.key)")
                )
                BluetoothDebug.log("    [depth \(depth)] \(className) \(found.key) → \(found.percent)%")
            }
        }

        for plane in registryPlanes {
            recurseChildren(of: entry, plane: plane, depth: depth, into: &candidates, path: path)
        }
    }

    private static func recurseChildren(
        of entry: io_registry_entry_t,
        plane: String,
        depth: Int,
        into candidates: inout [BatteryCandidate],
        path: String
    ) {
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, plane, &childIterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(childIterator) }

        while case let child = IOIteratorNext(childIterator), child != 0 {
            collectFromEntry(child, depth: depth + 1, into: &candidates, path: path)
            IOObjectRelease(child)
        }
    }

    private static func registryEntryName(_ entry: io_registry_entry_t) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS else { return nil }
        let name = String(cString: nameBuffer)
        return name.isEmpty ? nil : name
    }

    // MARK: - Property helpers

    private static func copyProperties(for entry: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            entry,
            &properties,
            kCFAllocatorDefault,
            0
        )
        guard result == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }

    // MARK: - Device matching

    private static func entryMatchesDevice(entry: io_registry_entry_t, address: String, name: String) -> Bool {
        entryMatches(entry: entry, address: address, name: name)
            || entryMatchesNameOnly(entry: entry, name: name)
            || entryMatchesFuzzyName(entry: entry, name: name)
    }

    private static func entryMatches(
        entry: io_registry_entry_t,
        address: String,
        name: String
    ) -> Bool {
        guard let properties = copyProperties(for: entry) else { return false }

        let normalizedTargetAddress = BluetoothAddressNormalizer.normalize(address)
        let normalizedTargetName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if !normalizedTargetAddress.isEmpty {
            for key in addressPropertyKeys {
                if let value = properties[key], addressMatches(value, target: normalizedTargetAddress) {
                    return true
                }
            }
        }

        if !normalizedTargetName.isEmpty {
            for key in namePropertyKeys {
                if let value = properties[key] as? String, namesMatch(value, target: normalizedTargetName) {
                    return true
                }
            }
        }

        return false
    }

    private static func entryMatchesNameOnly(entry: io_registry_entry_t, name: String) -> Bool {
        guard let properties = copyProperties(for: entry) else { return false }
        let target = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }

        for key in namePropertyKeys {
            if let value = properties[key] as? String, namesMatch(value, target: target) {
                return true
            }
        }
        return false
    }

    /// Fuzzy match for Logitech / shortened product names in HID nodes.
    private static func entryMatchesFuzzyName(entry: io_registry_entry_t, name: String) -> Bool {
        guard let properties = copyProperties(for: entry) else { return false }
        let targetTokens = tokenize(name)
        guard !targetTokens.isEmpty else { return false }

        for key in namePropertyKeys {
            guard let value = properties[key] as? String else { continue }
            let registryTokens = tokenize(value)
            let overlap = targetTokens.filter { token in
                registryTokens.contains { $0.contains(token) || token.contains($0) }
            }
            if overlap.count >= max(1, min(targetTokens.count, 2)) {
                return true
            }
        }
        return false
    }

    private static func tokenize(_ name: String) -> [String] {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func namesMatch(_ registryName: String, target: String) -> Bool {
        let lhs = registryName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !target.isEmpty else { return false }
        return lhs == target || lhs.contains(target) || target.contains(lhs)
    }

    private static func addressMatches(_ value: Any, target: String) -> Bool {
        guard !target.isEmpty else { return false }

        if let string = value as? String {
            return BluetoothAddressNormalizer.normalize(string) == target
        }

        if let data = value as? Data {
            return BluetoothAddressNormalizer.normalize(data) == target
        }

        if let number = value as? NSNumber {
            return BluetoothAddressNormalizer.normalize(number.uint64Value) == target
        }

        return false
    }
}

// MARK: - Battery Candidate

private struct BatteryCandidate {
    let percent: Int
    let priority: Int
    let source: String

    static func selectBest(from candidates: [BatteryCandidate]) -> BatteryCandidate? {
        candidates.min { $0.priority < $1.priority }
    }
}

// MARK: - Battery Value Normalizer

enum BatteryValueNormalizer {
    struct BatteryReading {
        let percent: Int
        let priority: Int
        let key: String
    }

    /// Extracts the best battery reading from a registry property dictionary.
    static func extractBattery(from properties: [String: Any]) -> BatteryReading? {
        if let airPods = airPodsAggregate(from: properties) {
            return airPods
        }

        for key in IORegistryBatteryReader.batteryKeys {
            guard let value = properties[key] else { continue }
            if let percent = percent(from: value, key: key) {
                return BatteryReading(percent: percent, priority: priority(for: key), key: key)
            }
        }

        if let capacity = capacityRatio(from: properties) {
            return BatteryReading(percent: capacity, priority: 8, key: "CurrentCapacity/MaxCapacity")
        }

        return nil
    }

    // MARK: - AirPods (left / right / case)

    private static func airPodsAggregate(from properties: [String: Any]) -> BatteryReading? {
        let left = properties["BatteryPercentLeft"].flatMap { percent(from: $0, key: "BatteryPercentLeft") }
        let right = properties["BatteryPercentRight"].flatMap { percent(from: $0, key: "BatteryPercentRight") }
        let caseBatt = properties["BatteryPercentCase"].flatMap { percent(from: $0, key: "BatteryPercentCase") }
        let single = properties["BatteryPercent"].flatMap { percent(from: $0, key: "BatteryPercent") }

        let budValues = [left, right].compactMap { $0 }
        if let minBud = budValues.min() {
            return BatteryReading(percent: minBud, priority: 2, key: "BatteryPercentLeft/Right")
        }

        if let caseBatt {
            return BatteryReading(percent: caseBatt, priority: 3, key: "BatteryPercentCase")
        }

        if let single {
            return BatteryReading(percent: single, priority: 1, key: "BatteryPercent")
        }

        return nil
    }

    // MARK: - Capacity ratio

    private static func capacityRatio(from properties: [String: Any]) -> Int? {
        guard let maxValue = properties["MaxCapacity"],
              let currentValue = properties["CurrentCapacity"],
              let max = extractInt(from: maxValue),
              let current = extractInt(from: currentValue),
              max > 0, current >= 0 else {
            return nil
        }

        let percent = Int((Double(current) / Double(max) * 100).rounded())
        guard (1...100).contains(percent) else { return nil }
        return percent
    }

    // MARK: - Key-specific parsing

    static func percent(from value: Any, key: String) -> Int? {
        guard let raw = extractInt(from: value) else { return nil }

        switch key {
        case "BatteryPercent", "BatteryPercentLeft", "BatteryPercentRight", "BatteryPercentCase",
             "AppleRawDeviceBatteryLevel":
            guard (1...100).contains(raw) else { return nil }
            return raw

        case "BatteryLevel", "AppleDeviceBatteryLevel":
            guard raw > 0 else { return nil }
            if (1...9).contains(raw) {
                return clamp((raw * 100) / 9)
            }
            if (10...100).contains(raw) {
                return raw
            }
            return nil

        default:
            guard key.lowercased().contains("battery"), raw > 0 else { return nil }
            if (1...100).contains(raw) { return raw }
            if (1...9).contains(raw) { return clamp((raw * 100) / 9) }
            return nil
        }
    }

    static func primaryPercent(from value: Any, key: String) -> Int? {
        percent(from: value, key: key)
    }

    static func priority(for key: String) -> Int {
        switch key {
        case "BatteryPercent": return 1
        case "BatteryPercentLeft", "BatteryPercentRight": return 2
        case "BatteryPercentCase": return 3
        case "AppleDeviceBatteryLevel", "AppleRawDeviceBatteryLevel": return 4
        case "BatteryLevel": return 5
        default: return 6
        }
    }

    // MARK: - Type-safe value extraction

    static func extractInt(from value: Any) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }

        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("%") {
                let digits = trimmed.dropLast().filter(\.isNumber)
                if let parsed = Int(digits) { return parsed }
            }
            let digits = trimmed.filter(\.isNumber)
            guard !digits.isEmpty, let parsed = Int(digits) else { return nil }
            return parsed
        }

        if let data = value as? Data {
            return extractInt(from: data)
        }

        if let array = value as? [Int], let first = array.first {
            return first
        }

        return nil
    }

    private static func extractInt(from data: Data) -> Int? {
        switch data.count {
        case 1:
            return Int(data[data.startIndex])
        case 2:
            return data.withUnsafeBytes { ptr in
                Int(ptr.load(as: UInt16.self))
            }
        case 4:
            return data.withUnsafeBytes { ptr in
                Int(ptr.load(as: UInt32.self))
            }
        default:
            return nil
        }
    }

    private static func clamp(_ value: Int) -> Int {
        min(100, max(1, value))
    }
}

// MARK: - Bluetooth Address Normalizer

enum BluetoothAddressNormalizer {
    static func normalize(_ address: String) -> String {
        address
            .uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .filter { $0.isHexDigit }
    }

    static func normalize(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    static func normalize(_ value: UInt64) -> String {
        String(format: "%012llX", value)
    }
}

// MARK: - Device Class Mapper

enum BluetoothDeviceClassMapper {
    static func deviceClass(for ioDevice: IOBluetoothDevice) -> BluetoothDevice.DeviceClass {
        let major = (ioDevice.classOfDevice >> 8) & 0x1F
        let minor = (ioDevice.classOfDevice >> 2) & 0x3F

        switch major {
        case 0x01:
            return mapPeripheralMinor(minor)
        case 0x02:
            return .phone
        case 0x04:
            return .headphones
        case 0x05:
            return mapPeripheralMinor(minor)
        case 0x06:
            return .peripheral
        case 0x07:
            return .wearable
        default:
            return inferFromName(ioDevice.name ?? "")
        }
    }

    static func deviceClass(forName name: String) -> BluetoothDevice.DeviceClass {
        inferFromName(name)
    }

    private static func mapPeripheralMinor(_ minor: UInt32) -> BluetoothDevice.DeviceClass {
        switch minor {
        case 0x01:
            return .keyboard
        case 0x02:
            return .mouse
        case 0x03:
            return .keyboard
        case 0x05:
            return .gameController
        default:
            return .peripheral
        }
    }

    private static func inferFromName(_ name: String) -> BluetoothDevice.DeviceClass {
        let lower = name.lowercased()
        if lower.contains("mouse") || lower.contains("mx master") || lower.contains("magic mouse") {
            return .mouse
        }
        if lower.contains("keyboard") || lower.contains("keychron") {
            return .keyboard
        }
        if lower.contains("trackpad") {
            return .trackpad
        }
        if lower.contains("airpods") || lower.contains("headphone") || lower.contains("beats") || lower.contains("bud") {
            return .headphones
        }
        if lower.contains("controller") || lower.contains("xbox") || lower.contains("playstation") {
            return .gameController
        }
        return .unknown
    }
}

// MARK: - IOBluetooth connection notifications (requires NSObject)

private final class BluetoothConnectionBridge: NSObject {
    var onConnectionChange: (@MainActor () -> Void)?

    @objc func deviceConnected(notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        BluetoothDebug.log("IOBluetooth connect: \(device.name ?? device.nameOrAddress ?? "device")")
        dispatchRefresh()
    }

    @objc func deviceDisconnected(notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        BluetoothDebug.log("IOBluetooth disconnect: \(device.name ?? device.nameOrAddress ?? "device")")
        dispatchRefresh()
    }

    private func dispatchRefresh() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onConnectionChange?()
            }
        }
    }
}

// MARK: - Runtime Resources

private final class BluetoothRuntimeResources {
    private var pollTimer: Timer?
    private var notificationObservers: [NSObjectProtocol] = []
    private var ioBluetoothNotifications: [IOBluetoothUserNotification] = []
    private let connectionBridge = BluetoothConnectionBridge()

    init(pollInterval: TimeInterval, onRefresh: @escaping @MainActor () -> Void) {
        connectionBridge.onConnectionChange = onRefresh

        if let connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: connectionBridge,
            selector: #selector(BluetoothConnectionBridge.deviceConnected(notification:device:))
        ) {
            ioBluetoothNotifications.append(connectNotification)
        }

        registerDisconnectNotifications(for: connectionBridge)

        let notificationNames = [
            kIOBluetoothDeviceNotificationNameConnected,
            kIOBluetoothDeviceNotificationNameDisconnected,
        ]

        for name in notificationNames {
            let observer = NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { _ in
                BluetoothDebug.log("NSNotification \(name) received")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        onRefresh()
                    }
                }
            }
            notificationObservers.append(observer)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onRefresh()
                }
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }

        BluetoothDebug.log("Registered IOBluetooth + NSNotification observers and poll timer (\(pollInterval)s)")
    }

    deinit {
        ioBluetoothNotifications.forEach { $0.unregister() }
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        pollTimer?.invalidate()
    }

    /// Disconnect notifications are per-device instance methods on `IOBluetoothDevice`.
    private func registerDisconnectNotifications(for bridge: BluetoothConnectionBridge) {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let recent = IOBluetoothDevice.recentDevices(32) as? [IOBluetoothDevice] ?? []
        var seenAddresses = Set<String>()

        for device in paired + recent {
            let key = device.addressString ?? "\(ObjectIdentifier(device))"
            guard seenAddresses.insert(key).inserted else { continue }

            if let notification = device.register(
                forDisconnectNotification: bridge,
                selector: #selector(BluetoothConnectionBridge.deviceDisconnected(notification:device:))
            ) {
                ioBluetoothNotifications.append(notification)
            }
        }

        BluetoothDebug.log("Registered disconnect notifications for \(seenAddresses.count) device(s)")
    }
}

// MARK: - Bluetooth Manager

@MainActor
@Observable
final class BluetoothManager {
    static let shared = BluetoothManager()

    private(set) var devices: [BluetoothDevice] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshed: Date?

    @ObservationIgnored
    private var runtime: BluetoothRuntimeResources?

    private let pollInterval: TimeInterval = 30

    private init() {
        BLEBatteryScanner.shared.ensureManager()
        runtime = BluetoothRuntimeResources(pollInterval: pollInterval) { [weak self] in
            Task { @MainActor in
                await self?.refreshDevices()
            }
        }
        Task { @MainActor in
            await self.refreshDevices()
        }
    }

    /// Performs the Bluetooth / IORegistry device scan (no minimum UI delay).
    func refreshDevices() async {
        guard !isRefreshing else {
            BluetoothDebug.log("refreshDevices() skipped — already in progress")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        BluetoothDebug.log("refreshDevices() started")

        await BluetoothBatteryEngine.refreshAllCaches()
        let discovered = fetchConnectedDevices()
        devices = discovered.sorted { lhs, rhs in
            if lhs.hasBatteryReading != rhs.hasBatteryReading {
                return lhs.hasBatteryReading && !rhs.hasBatteryReading
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        lastRefreshed = Date()

        BluetoothDebug.log("refreshDevices() finished — \(devices.count) device(s) in UI list")
        for device in devices {
            BluetoothDebug.log("  • \(device.displayName) connected=\(device.isConnected) battery=\(device.batteryDisplay)")
        }

        NotificationCenter.default.post(name: .chargeLinkDevicesDidUpdate, object: self)
    }

    var lowestBatteryPercent: Int? {
        devices.compactMap(\.batteryPercent).min()
    }

    // MARK: - Device Discovery

    private func fetchConnectedDevices() -> [BluetoothDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            BluetoothDebug.log("pairedDevices(): nil or unexpected type")
            return []
        }

        BluetoothDebug.log("pairedDevices(): returned \(paired.count) device(s)")

        var results: [BluetoothDevice] = []
        var seenIDs = Set<String>()

        for ioDevice in paired {
            let name = ioDevice.name ?? ioDevice.nameOrAddress ?? "Bluetooth Device"
            let address = ioDevice.addressString ?? "unknown-\(ObjectIdentifier(ioDevice))"
            let connected = ioDevice.isConnected()

            BluetoothDebug.log("  • '\(name)' @ \(address) isConnected=\(connected)")

            guard connected else { continue }

            let normalizedAddress = BluetoothAddressNormalizer.normalize(address)
            let id = normalizedAddress.isEmpty ? address : normalizedAddress
            guard seenIDs.insert(id).inserted else { continue }

            let reading = BluetoothBatteryEngine.resolveBattery(name: name, address: address)
            BluetoothDebug.log("    battery: \(reading.displayText) [\(reading.source)]")

            results.append(
                BluetoothDevice(
                    id: id,
                    name: name,
                    address: address,
                    batteryPercent: reading.percent,
                    batteryDetailText: reading.detailText,
                    deviceClass: BluetoothDeviceClassMapper.deviceClass(for: ioDevice),
                    isConnected: true
                )
            )
        }

        return results
    }
}

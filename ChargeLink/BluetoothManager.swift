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

// MARK: - IORegistry Battery Reader

/// Reads battery levels from IORegistry using public IOKit APIs.
enum IORegistryBatteryReader {
    /// Common battery keys found under Bluetooth / HID services in IORegistry.
    static let batteryPropertyKeys: [String] = [
        "BatteryPercent",
        "BatteryLevel",
        "AppleDeviceBatteryLevel",
        "kIOPSCurrentCapacityKey",
        "CurrentCapacity",
        "MaxCapacity",
    ]

    /// Keys used to correlate an IORegistry entry with a Bluetooth device.
    private static let addressPropertyKeys: [String] = [
        "DeviceAddress",
        "BluetoothAddress",
        "BD_ADDR",
        "address",
    ]

    private static let namePropertyKeys: [String] = [
        "Product",
        "ProductName",
        "IOName",
        "name",
    ]

    static func batteryPercent(name: String, address: String) -> Int? {
        if let fromMatching = searchBluetoothServices(address: address, name: name) {
            return fromMatching
        }

        return searchHIDBatteryServices(address: address, name: name)
    }

    // MARK: IOService tree search

    private static func searchBluetoothServices(address: String, name: String) -> Int? {
        searchServices(matching: "IOBluetoothDevice", address: address, name: name)
    }

    private static func searchHIDBatteryServices(address: String, name: String) -> Int? {
        let classes = [
            "AppleDeviceManagementHIDEventService",
            "IOHIDEventService",
            "BatteryData",
            "IOPMrootDomain",
        ]
        for className in classes {
            if let percent = searchServices(matching: className, address: address, name: name) {
                return percent
            }
        }
        return nil
    }

    private static func searchServices(
        matching className: String,
        address: String,
        name: String
    ) -> Int? {
        guard let matching = IOServiceMatching(className) else { return nil }
        var iterator: io_iterator_t = 0
        let kernResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kernResult == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var bestMatch: Int?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            if entryMatches(entry: entry, address: address, name: name) {
                if let percent = readBattery(fromRegistryEntry: entry) {
                    return percent
                }
                if let childPercent = readBatteryFromChildren(of: entry) {
                    return childPercent
                }
            } else if let percent = readBatteryFromChildren(of: entry, address: address, name: name) {
                bestMatch = percent
            }
        }
        return bestMatch
    }

    private static func readBatteryFromChildren(
        of entry: io_registry_entry_t,
        address: String? = nil,
        name: String? = nil
    ) -> Int? {
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        while case let child = IOIteratorNext(childIterator), child != 0 {
            defer { IOObjectRelease(child) }

            let matches: Bool
            if let address, let name {
                matches = entryMatches(entry: child, address: address, name: name)
            } else {
                matches = true
            }

            if matches {
                if let percent = readBattery(fromRegistryEntry: child) {
                    return percent
                }
                if let nested = readBatteryFromChildren(of: child, address: address, name: name) {
                    return nested
                }
            }
        }
        return nil
    }

    static func readBattery(fromRegistryEntry entry: io_registry_entry_t) -> Int? {
        guard let properties = copyProperties(for: entry) else { return nil }

        for key in batteryPropertyKeys {
            if let value = properties[key] {
                if let percent = BatteryValueNormalizer.percent(from: value, properties: properties, key: key) {
                    return percent
                }
            }
        }
        return nil
    }

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

    private static func entryMatches(
        entry: io_registry_entry_t,
        address: String,
        name: String
    ) -> Bool {
        guard let properties = copyProperties(for: entry) else { return false }

        let normalizedTargetAddress = BluetoothAddressNormalizer.normalize(address)
        let normalizedTargetName = name.lowercased()

        for key in addressPropertyKeys {
            if let value = properties[key], addressMatches(value, target: normalizedTargetAddress) {
                return true
            }
        }

        for key in namePropertyKeys {
            if let value = properties[key] as? String,
               !normalizedTargetName.isEmpty,
               value.lowercased().contains(normalizedTargetName)
                || normalizedTargetName.contains(value.lowercased()) {
                return true
            }
        }

        return false
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

// MARK: - Battery Value Normalizer

enum BatteryValueNormalizer {
    static func percent(from value: Any, properties: [String: Any], key: String) -> Int? {
        if key == "MaxCapacity", let max = value as? NSNumber {
            if let current = properties["CurrentCapacity"] as? NSNumber, max.intValue > 0 {
                return clamp((current.doubleValue / max.doubleValue) * 100)
            }
            return nil
        }

        if let number = value as? NSNumber {
            return percent(from: number.intValue)
        }

        if let string = value as? String {
            let digits = string.filter(\.isNumber)
            if let parsed = Int(digits) {
                return percent(from: parsed)
            }
        }

        return nil
    }

    private static func percent(from raw: Int) -> Int? {
        switch raw {
        case 0...9:
            return clamp((raw * 100) / 9)
        case 10...100:
            return clamp(raw)
        case 101...1000:
            return clamp(raw / 10)
        default:
            return nil
        }
    }

    private static func clamp(_ value: Double) -> Int {
        Int(min(100, max(0, value.rounded())))
    }

    private static func clamp(_ value: Int) -> Int {
        min(100, max(0, value))
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

// MARK: - Bluetooth Manager

@MainActor
@Observable
final class BluetoothManager {
    static let shared = BluetoothManager()

    private(set) var devices: [BluetoothDevice] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshed: Date?

    private nonisolated var pollTimer: Timer?
    private nonisolated var notificationObservers: [NSObjectProtocol] = []
    private let pollInterval: TimeInterval = 45

    private init() {
        registerForDeviceNotifications()
        startPolling()
        refresh()
    }

    nonisolated deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        pollTimer?.invalidate()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let discovered = fetchConnectedDevices()
        devices = discovered.sorted { lhs, rhs in
            if lhs.hasBatteryReading != rhs.hasBatteryReading {
                return lhs.hasBatteryReading && !rhs.hasBatteryReading
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        lastRefreshed = Date()
        isRefreshing = false
        NotificationCenter.default.post(name: .chargeLinkDevicesDidUpdate, object: self)
    }

    var lowestBatteryPercent: Int? {
        devices.compactMap(\.batteryPercent).min()
    }

    // MARK: - Device Discovery

    private func fetchConnectedDevices() -> [BluetoothDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        var results: [BluetoothDevice] = []
        var seenAddresses = Set<String>()

        for ioDevice in paired where ioDevice.isConnected() {
            let address = ioDevice.addressString ?? UUID().uuidString
            let normalizedAddress = BluetoothAddressNormalizer.normalize(address)
            guard !seenAddresses.contains(normalizedAddress) else { continue }
            seenAddresses.insert(normalizedAddress)

            let name = ioDevice.name ?? ioDevice.nameOrAddress ?? "Bluetooth Device"
            let battery = IORegistryBatteryReader.batteryPercent(name: name, address: address)

            let device = BluetoothDevice(
                id: normalizedAddress.isEmpty ? address : normalizedAddress,
                name: name,
                address: address,
                batteryPercent: battery,
                deviceClass: BluetoothDeviceClassMapper.deviceClass(for: ioDevice),
                isConnected: ioDevice.isConnected()
            )
            results.append(device)
        }

        return results
    }

    // MARK: - Notifications

    private func registerForDeviceNotifications() {
        let notificationNames = [
            kIOBluetoothDeviceNotificationNameConnected,
            kIOBluetoothDeviceNotificationNameDisconnected,
        ]

        for name in notificationNames {
            let observer = NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.refresh()
                }
            }
            notificationObservers.append(observer)
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.refresh()
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }
}

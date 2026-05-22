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

/// Reads battery from the IOBluetooth device subtree in IORegistry (public IOKit APIs).
enum IORegistryBatteryReader {
    static let primaryBatteryKeys = [
        "BatteryPercent",
        "BatteryLevel",
        "AppleDeviceBatteryLevel",
    ]

    static let maxSearchDepth = 20

    private static let addressPropertyKeys = [
        "DeviceAddress",
        "BluetoothAddress",
        "BD_ADDR",
        "address",
    ]

    private static let namePropertyKeys = [
        "Product",
        "ProductName",
        "IOName",
        "name",
    ]

    static func batteryPercent(name: String, address: String) -> Int? {
        BluetoothDebug.log("IORegistry search for '\(name)' @ \(address)")

        guard let rootEntry = findBluetoothDeviceEntry(address: address, name: name) else {
            BluetoothDebug.log("  → no matching IOBluetoothDevice registry entry")
            return nil
        }
        defer { IOObjectRelease(rootEntry) }

        if let percent = scanBluetoothDeviceTree(entry: rootEntry, depth: 0) {
            BluetoothDebug.log("  → battery \(percent)%")
            return percent
        }

        BluetoothDebug.log("  → primary battery keys not found in tree")
        return nil
    }

    // MARK: - Find IOBluetoothDevice entry

    private static func findBluetoothDeviceEntry(address: String, name: String) -> io_registry_entry_t? {
        guard let matching = IOServiceMatching("IOBluetoothDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var fallbackByName: io_registry_entry_t?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if entryMatches(entry: entry, address: address, name: name) {
                IOObjectRetain(entry)
                return entry
            }
            if fallbackByName == nil, entryMatchesNameOnly(entry: entry, name: name) {
                IOObjectRetain(entry)
                fallbackByName = entry
                continue
            }
            IOObjectRelease(entry)
        }
        return fallbackByName
    }

    // MARK: - Recursive tree scan

    private static func scanBluetoothDeviceTree(entry: io_registry_entry_t, depth: Int) -> Int? {
        guard depth <= maxSearchDepth else { return nil }

        if let percent = readPrimaryBatteryKeys(from: entry) {
            return percent
        }

        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        while case let child = IOIteratorNext(childIterator), child != 0 {
            defer { IOObjectRelease(child) }
            if let percent = scanBluetoothDeviceTree(entry: child, depth: depth + 1) {
                return percent
            }
        }
        return nil
    }

    private static func readPrimaryBatteryKeys(from entry: io_registry_entry_t) -> Int? {
        guard let properties = copyProperties(for: entry) else { return nil }

        for key in primaryBatteryKeys {
            guard let value = properties[key] else { continue }
            if let percent = BatteryValueNormalizer.primaryPercent(from: value, key: key) {
                BluetoothDebug.log("    key \(key) → \(percent)%")
                return percent
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
}

// MARK: - Battery Value Normalizer

enum BatteryValueNormalizer {
    /// Parses only Apple-documented Bluetooth battery keys. Returns `nil` instead of 0 when unknown.
    static func primaryPercent(from value: Any, key: String) -> Int? {
        guard let raw = extractInt(from: value) else { return nil }

        switch key {
        case "BatteryPercent":
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
            return nil
        }
    }

    private static func extractInt(from value: Any) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            let digits = string.filter(\.isNumber)
            guard !digits.isEmpty, let parsed = Int(digits) else { return nil }
            return parsed
        }
        return nil
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
        BluetoothPermissionManager.shared.requestAccessIfNeeded()
        runtime = BluetoothRuntimeResources(pollInterval: pollInterval) { [weak self] in
            self?.refresh()
        }
        Task { @MainActor in
            self.refresh()
        }
    }

    func refresh() {
        guard !isRefreshing else {
            BluetoothDebug.log("refresh() skipped — already in progress")
            return
        }
        isRefreshing = true
        BluetoothDebug.log("refresh() started")

        let discovered = fetchConnectedDevices()
        devices = discovered.sorted { lhs, rhs in
            if lhs.hasBatteryReading != rhs.hasBatteryReading {
                return lhs.hasBatteryReading && !rhs.hasBatteryReading
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        lastRefreshed = Date()
        isRefreshing = false

        BluetoothDebug.log("refresh() finished — \(devices.count) device(s) in UI list")
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

            let battery = IORegistryBatteryReader.batteryPercent(name: name, address: address)
            BluetoothDebug.log("    battery: \(battery.map { "\($0)%" } ?? "unknown (—)")")

            results.append(
                BluetoothDevice(
                    id: id,
                    name: name,
                    address: address,
                    batteryPercent: battery,
                    deviceClass: BluetoothDeviceClassMapper.deviceClass(for: ioDevice),
                    isConnected: true
                )
            )
        }

        return results
    }
}

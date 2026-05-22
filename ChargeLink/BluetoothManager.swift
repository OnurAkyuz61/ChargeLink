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

/// Reads battery levels from IORegistry using public IOKit APIs.
enum IORegistryBatteryReader {
    static let maxSearchDepth = 16

    /// Battery keys on Bluetooth / HID / power services (including AirPods case).
    static let batteryPropertyKeys: [String] = [
        "BatteryPercent",
        "BatteryLevel",
        "AppleDeviceBatteryLevel",
        "BatteryPercentCase",
        "BatteryPercentLeft",
        "BatteryPercentRight",
        "BatteryRemaining",
        "DeviceBatteryLevel",
        "kIOPSCurrentCapacityKey",
        "CurrentCapacity",
        "MaxCapacity",
    ]

    private static let batteryKeySubstrings = ["battery", "power", "capacity"]

    private static let addressPropertyKeys: [String] = [
        "DeviceAddress",
        "BluetoothAddress",
        "BD_ADDR",
        "address",
        "HIDAddress",
    ]

    private static let namePropertyKeys: [String] = [
        "Product",
        "ProductName",
        "IOName",
        "name",
        "USB Product Name",
    ]

    private static let registryServiceClasses = [
        "IOBluetoothDevice",
        "IOBluetoothHCIUserClient",
        "AppleDeviceManagementHIDEventService",
        "IOHIDEventService",
        "BatteryData",
        "AppleBluetoothHIDDevice",
        "IOHIDDevice",
    ]

    static func batteryPercent(name: String, address: String) -> Int? {
        BluetoothDebug.log("IORegistry battery search for '\(name)' @ \(address)")

        if let matched = searchMatchingServices(name: name, address: address) {
            BluetoothDebug.log("  → matched service battery: \(matched)%")
            return matched
        }

        if let deep = deepScanAllServices(name: name, address: address) {
            BluetoothDebug.log("  → deep scan battery: \(deep)%")
            return deep
        }

        BluetoothDebug.log("  → no battery keys found in IORegistry")
        return nil
    }

    // MARK: - Targeted service search

    private static func searchMatchingServices(name: String, address: String) -> Int? {
        for className in registryServiceClasses {
            if let percent = searchServices(matching: className, address: address, name: name, requireMatch: true) {
                return percent
            }
        }
        return nil
    }

    private static func deepScanAllServices(name: String, address: String) -> Int? {
        var best: Int?
        for className in registryServiceClasses {
            if let percent = searchServices(matching: className, address: address, name: name, requireMatch: false) {
                best = percent
            }
        }
        return best
    }

    private static func searchServices(
        matching className: String,
        address: String,
        name: String,
        requireMatch: Bool
    ) -> Int? {
        guard let matching = IOServiceMatching(className) else { return nil }
        var iterator: io_iterator_t = 0
        let kernResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kernResult == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var bestMatch: Int?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            let matches = entryMatches(entry: entry, address: address, name: name)
            if matches || !requireMatch {
                if let percent = deepScan(entry: entry, depth: 0, address: address, name: name, strictMatch: requireMatch && matches) {
                    if matches {
                        return percent
                    }
                    bestMatch = percent
                }
            }
        }
        return bestMatch
    }

    /// Recursively walks the IORegistry service tree for battery properties.
    static func deepScan(
        entry: io_registry_entry_t,
        depth: Int,
        address: String,
        name: String,
        strictMatch: Bool
    ) -> Int? {
        guard depth <= maxSearchDepth else { return nil }

        if !strictMatch || entryMatches(entry: entry, address: address, name: name) {
            if let percent = readBattery(fromRegistryEntry: entry) {
                return percent
            }
            if let properties = copyProperties(for: entry),
               let percent = scanFuzzyBatteryKeys(in: properties) {
                return percent
            }
        }

        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        while case let child = IOIteratorNext(childIterator), child != 0 {
            defer { IOObjectRelease(child) }
            if let percent = deepScan(
                entry: child,
                depth: depth + 1,
                address: address,
                name: name,
                strictMatch: false
            ) {
                return percent
            }
        }
        return nil
    }

    static func readBattery(fromRegistryEntry entry: io_registry_entry_t) -> Int? {
        guard let properties = copyProperties(for: entry) else { return nil }

        for key in batteryPropertyKeys {
            if let value = properties[key],
               let percent = BatteryValueNormalizer.percent(from: value, properties: properties, key: key) {
                return percent
            }
        }
        return scanFuzzyBatteryKeys(in: properties)
    }

    private static func scanFuzzyBatteryKeys(in properties: [String: Any]) -> Int? {
        for (key, value) in properties {
            let lower = key.lowercased()
            guard batteryKeySubstrings.contains(where: { lower.contains($0) }) else { continue }
            if let percent = BatteryValueNormalizer.percent(from: value, properties: properties, key: key) {
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

    // MARK: - Registry-only device discovery

    struct RegistryDeviceInfo {
        let name: String
        let address: String
        let batteryPercent: Int?
    }

    static func discoverDevicesFromRegistry() -> [RegistryDeviceInfo] {
        guard let matching = IOServiceMatching("IOBluetoothDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var results: [RegistryDeviceInfo] = []
        var seen = Set<String>()

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let properties = copyProperties(for: entry) else { continue }

            let name = registryName(from: properties) ?? "Bluetooth Device"
            let address = registryAddress(from: properties) ?? UUID().uuidString
            let normalized = BluetoothAddressNormalizer.normalize(address)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)

            let battery = deepScan(entry: entry, depth: 0, address: address, name: name, strictMatch: false)
            results.append(RegistryDeviceInfo(name: name, address: address, batteryPercent: battery))
            BluetoothDebug.log("IORegistry IOBluetoothDevice: \(name) @ \(address) battery=\(battery.map(String.init) ?? "nil")")
        }

        return results
    }

    private static func registryName(from properties: [String: Any]) -> String? {
        for key in namePropertyKeys {
            if let value = properties[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func registryAddress(from properties: [String: Any]) -> String? {
        for key in addressPropertyKeys {
            guard let value = properties[key] else { continue }
            if let string = value as? String, !string.isEmpty {
                return string
            }
            if let data = value as? Data, !data.isEmpty {
                return BluetoothAddressNormalizer.normalize(data)
            }
        }
        return nil
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

    @objc func deviceConnected(notification: IOBluetoothUserNotification) {
        BluetoothDebug.log("IOBluetooth connect notification received")
        dispatchRefresh()
    }

    @objc func deviceDisconnected(notification: IOBluetoothUserNotification) {
        BluetoothDebug.log("IOBluetooth disconnect notification received")
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

        ioBluetoothNotifications.append(
            IOBluetoothDevice.register(
                forConnectNotifications: connectionBridge,
                selector: #selector(BluetoothConnectionBridge.deviceConnected(notification:)),
                of: nil
            )
        )
        ioBluetoothNotifications.append(
            IOBluetoothDevice.register(
                forDisconnectNotifications: connectionBridge,
                selector: #selector(BluetoothConnectionBridge.deviceDisconnected(notification:)),
                of: nil
            )
        )

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
        refresh()
        runtime = BluetoothRuntimeResources(pollInterval: pollInterval) { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        guard !isRefreshing else {
            BluetoothDebug.log("refresh() skipped — already in progress")
            return
        }
        isRefreshing = true
        BluetoothDebug.log("refresh() started")

        let discovered = fetchAllDevices()
        devices = discovered.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected {
                return lhs.isConnected && !rhs.isConnected
            }
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

    private func fetchAllDevices() -> [BluetoothDevice] {
        var merged: [String: BluetoothDevice] = [:]

        ingestIOBluetoothDevices(into: &merged, source: "pairedDevices") {
            IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]
        }

        ingestIOBluetoothDevices(into: &merged, source: "recentDevices") {
            IOBluetoothDevice.recentDevices(32) as? [IOBluetoothDevice]
        }

        ingestRegistryDevices(into: &merged)

        return Array(merged.values)
    }

    private func ingestIOBluetoothDevices(
        into merged: inout [String: BluetoothDevice],
        source: String,
        list: () -> [IOBluetoothDevice]?
    ) {
        guard let devices = list() else {
            BluetoothDebug.log("\(source): nil or wrong type")
            return
        }

        BluetoothDebug.log("\(source): returned \(devices.count) device(s)")

        for ioDevice in devices {
            let address = ioDevice.addressString ?? "unknown-\(ObjectIdentifier(ioDevice))"
            let normalizedAddress = BluetoothAddressNormalizer.normalize(address)
            let id = normalizedAddress.isEmpty ? address : normalizedAddress
            let name = ioDevice.name ?? ioDevice.nameOrAddress ?? "Bluetooth Device"
            let connected = ioDevice.isConnected()
            let battery = IORegistryBatteryReader.batteryPercent(name: name, address: address)

            BluetoothDebug.log(
                "\(source) item: name='\(name)' address=\(address) connected=\(connected) battery=\(battery.map(String.init) ?? "nil")"
            )

            let device = BluetoothDevice(
                id: id,
                name: name,
                address: address,
                batteryPercent: battery,
                deviceClass: BluetoothDeviceClassMapper.deviceClass(for: ioDevice),
                isConnected: connected
            )
            mergeDevice(device, into: &merged)
        }
    }

    private func ingestRegistryDevices(into merged: inout [String: BluetoothDevice]) {
        let registryDevices = IORegistryBatteryReader.discoverDevicesFromRegistry()
        BluetoothDebug.log("IORegistry discoverDevicesFromRegistry: \(registryDevices.count) entries")

        for info in registryDevices {
            let normalizedAddress = BluetoothAddressNormalizer.normalize(info.address)
            let id = normalizedAddress.isEmpty ? info.address : normalizedAddress

            let device = BluetoothDevice(
                id: id,
                name: info.name,
                address: info.address,
                batteryPercent: info.batteryPercent,
                deviceClass: BluetoothDeviceClassMapper.deviceClass(forName: info.name),
                isConnected: true
            )
            mergeDevice(device, into: &merged)
        }
    }

    private func mergeDevice(_ device: BluetoothDevice, into merged: inout [String: BluetoothDevice]) {
        if var existing = merged[device.id] {
            if device.batteryPercent != nil { existing = deviceWithBattery(from: device, existing: existing) }
            if device.isConnected { existing = deviceWithConnection(from: device, existing: existing) }
            if existing.name == "Bluetooth Device", device.name != "Bluetooth Device" {
                existing = BluetoothDevice(
                    id: existing.id,
                    name: device.name,
                    address: device.address,
                    batteryPercent: existing.batteryPercent ?? device.batteryPercent,
                    deviceClass: device.deviceClass,
                    isConnected: existing.isConnected || device.isConnected
                )
            }
            merged[device.id] = existing
        } else {
            merged[device.id] = device
        }
    }

    private func deviceWithBattery(from device: BluetoothDevice, existing: BluetoothDevice) -> BluetoothDevice {
        BluetoothDevice(
            id: existing.id,
            name: existing.name,
            address: existing.address,
            batteryPercent: device.batteryPercent ?? existing.batteryPercent,
            deviceClass: existing.deviceClass,
            isConnected: existing.isConnected || device.isConnected
        )
    }

    private func deviceWithConnection(from device: BluetoothDevice, existing: BluetoothDevice) -> BluetoothDevice {
        BluetoothDevice(
            id: existing.id,
            name: existing.name,
            address: existing.address,
            batteryPercent: existing.batteryPercent ?? device.batteryPercent,
            deviceClass: existing.deviceClass,
            isConnected: true
        )
    }
}

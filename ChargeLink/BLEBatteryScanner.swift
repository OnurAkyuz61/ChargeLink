//
//  BLEBatteryScanner.swift
//  ChargeLink
//
//  Reads GATT Battery Service (0x180F) / Level (0x2A19) via CoreBluetooth.
//

import CoreBluetooth
import Foundation

/// Scans connected BLE peripherals for standard Battery Service characteristics.
@MainActor
final class BLEBatteryScanner: NSObject {
    static let shared = BLEBatteryScanner()

    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")

    private var centralManager: CBCentralManager?
    private var peripheralDelegates: [UUID: BLEPeripheralBatteryDelegate] = [:]
    private var readingsByName: [String: Int] = [:]

    private var poweredOnContinuation: CheckedContinuation<Void, Never>?
    private var scanContinuation: CheckedContinuation<Void, Never>?
    private var pendingPeripheralIDs: Set<UUID> = []
    private let poweredOnTimeoutSeconds: UInt64 = 5
    private let scanTimeoutSeconds: UInt64 = 8

    private override init() {
        super.init()
    }

    func ensureManager() {
        guard centralManager == nil else { return }
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    /// Refreshes BLE battery cache; call before merging with IOBluetooth device list.
    func refresh() async -> [String: Int] {
        ensureManager()
        await waitUntilPoweredOn()

        guard let centralManager else { return [:] }

        if #available(macOS 10.15, *) {
            BluetoothDebug.log("BLE: authorization → \(CBCentralManager.authorization.rawValue)")
        }
        BluetoothDebug.log("BLE: state → \(centralManager.state.rawValue)")

        guard centralManager.state == .poweredOn else {
            BluetoothDebug.log("BLE: central not powered on — grant Bluetooth in System Settings → Privacy")
            return [:]
        }

        readingsByName = [:]
        peripheralDelegates = [:]

        var peripherals = centralManager.retrieveConnectedPeripherals(withServices: [batteryServiceUUID])
        BluetoothDebug.log("BLE: retrieveConnectedPeripherals(180F) → \(peripherals.count)")

        if peripherals.isEmpty {
            peripherals = centralManager.retrieveConnectedPeripherals(withServices: [])
            BluetoothDebug.log("BLE: fallback all connected → \(peripherals.count)")
        }

        guard !peripherals.isEmpty else { return [:] }

        pendingPeripheralIDs = Set(peripherals.map(\.identifier))
        await withCheckedContinuation { continuation in
            scanContinuation = continuation
            for peripheral in peripherals {
                let delegate = BLEPeripheralBatteryDelegate(
                    scanner: self,
                    serviceUUID: batteryServiceUUID,
                    levelUUID: batteryLevelCharacteristicUUID
                )
                peripheralDelegates[peripheral.identifier] = delegate
                peripheral.delegate = delegate

                if peripheral.state == .connected {
                    BluetoothDebug.log("BLE: \(peripheral.name ?? "?") already connected — discovering")
                    delegate.discoverBattery(on: peripheral)
                } else {
                    BluetoothDebug.log("BLE: \(peripheral.name ?? "?") state=\(peripheral.state.rawValue) — connecting")
                    centralManager.connect(peripheral, options: nil)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: scanTimeoutSeconds * 1_000_000_000)
                self.forceFinishScan()
            }
        }

        BluetoothDebug.log("BLE: readings → \(readingsByName)")
        return readingsByName
    }

    func allReadings() -> [String: Int] {
        readingsByName
    }

    func percent(matchingDeviceName name: String) -> Int? {
        let key = DeviceNameMatcher.normalize(name)
        if let direct = readingsByName[key] { return direct }
        for (cachedName, percent) in readingsByName {
            if DeviceNameMatcher.matches(cachedName, target: key) || DeviceNameMatcher.matches(key, target: cachedName) {
                return percent
            }
        }
        return nil
    }

    fileprivate func storeReading(name: String?, percent: Int) {
        guard (1...100).contains(percent) else { return }
        guard let name else { return }
        let key = DeviceNameMatcher.normalize(name)
        readingsByName[key] = percent
        BluetoothDebug.log("BLE: stored \(name) → \(percent)%")
    }

    fileprivate func peripheralFinished(_ id: UUID) {
        pendingPeripheralIDs.remove(id)
        finishScanIfNeeded()
    }

    private func finishScanIfNeeded() {
        guard pendingPeripheralIDs.isEmpty else { return }
        resumeScanContinuation()
    }

    private func forceFinishScan() {
        pendingPeripheralIDs.removeAll()
        resumeScanContinuation()
    }

    private func resumeScanContinuation() {
        guard let scanContinuation else { return }
        self.scanContinuation = nil
        scanContinuation.resume()
    }

    private func waitUntilPoweredOn() async {
        guard let centralManager else { return }
        if centralManager.state == .poweredOn { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    self.poweredOnContinuation = continuation
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: self.poweredOnTimeoutSeconds * 1_000_000_000)
                await MainActor.run {
                    if let poweredOnContinuation = self.poweredOnContinuation {
                        self.poweredOnContinuation = nil
                        poweredOnContinuation.resume()
                    }
                }
            }
            await group.waitForAll()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEBatteryScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            BluetoothDebug.log("BLE: state → \(central.state.rawValue)")
            if central.state == .poweredOn, let poweredOnContinuation {
                self.poweredOnContinuation = nil
                poweredOnContinuation.resume()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            BluetoothDebug.log("BLE: didConnect \(peripheral.name ?? "?")")
            guard let delegate = peripheralDelegates[peripheral.identifier] else {
                peripheralFinished(peripheral.identifier)
                return
            }
            delegate.discoverBattery(on: peripheral)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            BluetoothDebug.log("BLE: didFailToConnect \(peripheral.name ?? "?") — \(error?.localizedDescription ?? "unknown")")
            peripheralFinished(peripheral.identifier)
        }
    }
}

// MARK: - Per-peripheral delegate

@MainActor
private final class BLEPeripheralBatteryDelegate: NSObject, CBPeripheralDelegate {
    private weak var scanner: BLEBatteryScanner?
    private let serviceUUID: CBUUID
    private let levelUUID: CBUUID
    private var didComplete = false

    init(scanner: BLEBatteryScanner, serviceUUID: CBUUID, levelUUID: CBUUID) {
        self.scanner = scanner
        self.serviceUUID = serviceUUID
        self.levelUUID = levelUUID
    }

    func discoverBattery(on peripheral: CBPeripheral) {
        guard peripheral.state == .connected else {
            BluetoothDebug.log("BLE: skip discover — \(peripheral.name ?? "?") not connected")
            complete(peripheral)
            return
        }
        if let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) {
            readBattery(from: service, peripheral: peripheral)
        } else {
            peripheral.discoverServices(nil)
        }
    }

    private func readBattery(from service: CBService, peripheral: CBPeripheral) {
        if let characteristic = service.characteristics?.first(where: { $0.uuid == levelUUID }) {
            requestValue(for: characteristic, on: peripheral)
        } else {
            peripheral.discoverCharacteristics([levelUUID], for: service)
        }
    }

    private func requestValue(for characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        if let data = characteristic.value, let percent = Self.parseBatteryData(data) {
            scanner?.storeReading(name: peripheral.name, percent: percent)
            complete(peripheral)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil, peripheral.state == .connected, let services = peripheral.services else {
                self.complete(peripheral)
                return
            }
            if let batteryService = services.first(where: { $0.uuid == self.serviceUUID }) {
                self.readBattery(from: batteryService, peripheral: peripheral)
                return
            }
            for service in services {
                if let chars = service.characteristics,
                   let characteristic = chars.first(where: { $0.uuid == self.levelUUID }) {
                    self.requestValue(for: characteristic, on: peripheral)
                    return
                }
            }
            for service in services where service.characteristics == nil {
                peripheral.discoverCharacteristics([self.levelUUID], for: service)
                return
            }
            self.complete(peripheral)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard error == nil, peripheral.state == .connected,
                  let characteristic = service.characteristics?.first(where: { $0.uuid == self.levelUUID }) else {
                self.complete(peripheral)
                return
            }
            self.requestValue(for: characteristic, on: peripheral)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            defer { self.complete(peripheral) }
            guard error == nil, characteristic.uuid == self.levelUUID,
                  let data = characteristic.value,
                  let percent = Self.parseBatteryData(data) else { return }
            self.scanner?.storeReading(name: peripheral.name, percent: percent)
        }
    }

    private func complete(_ peripheral: CBPeripheral) {
        guard !didComplete else { return }
        didComplete = true
        scanner?.peripheralFinished(peripheral.identifier)
    }

    private static func parseBatteryData(_ data: Data) -> Int? {
        guard let byte = data.first else { return nil }
        let value = Int(byte)
        guard (0...100).contains(value), value > 0 else { return nil }
        return value
    }
}

//
//  BatteryViewModel.swift
//  ChargeLink
//

import AppKit
import Foundation
import Observation

/// Holds a NotificationCenter observer and unregisters it on deallocation.
private final class DevicesUpdateObserver {
    private var token: NSObjectProtocol?

    init(manager: BluetoothManager, handler: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .chargeLinkDevicesDidUpdate,
            object: manager,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

enum ScanningMessages {
    static let rotating = [
        "Şu an bağlı cihazlar taranıyor...",
        "IORegistry sorgulanıyor...",
        "AirPods durumu alınıyor...",
        "Bluetooth pil verileri okunuyor...",
        "Eşleştirilmiş cihazlar kontrol ediliyor...",
    ]
}

/// Bridges `BluetoothManager` data into SwiftUI-friendly state and actions.
@MainActor
@Observable
final class BatteryViewModel {
    private let manager: BluetoothManager

    @ObservationIgnored
    private var devicesUpdateObserver: DevicesUpdateObserver?

    @ObservationIgnored
    private var scanTask: Task<Void, Never>?

    @ObservationIgnored
    private var messageRotationTask: Task<Void, Never>?

    private(set) var devices: [BluetoothDevice] = []
    private(set) var isScanning = false
    private(set) var scanningStatusMessage = ScanningMessages.rotating[0]
    private(set) var scanDidFail = false
    private(set) var lastRefreshed: Date?

    var menuBarSymbolName: String {
        DeviceIcon.menuBarSymbol(lowestBattery: lowestBatteryPercent)
    }

    var isEmpty: Bool {
        !isScanning && devices.isEmpty
    }

    private var lowestBatteryPercent: Int? {
        devices.compactMap(\.batteryPercent).min()
    }

    var statusSubtitle: String {
        if isScanning { return scanningStatusMessage }
        if scanDidFail { return "Tarama tamamlanamadı" }
        guard let lastRefreshed else { return "Henüz tarama yapılmadı" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Güncellendi \(formatter.localizedString(for: lastRefreshed, relativeTo: Date()))"
    }

    init(manager: BluetoothManager) {
        self.manager = manager
        syncFromManager()
        devicesUpdateObserver = DevicesUpdateObserver(manager: manager) { [weak self] in
            self?.syncFromManager()
        }
    }

    private func syncFromManager() {
        guard !isScanning else { return }
        devices = manager.devices
        lastRefreshed = manager.lastRefreshed
    }

    func refresh() {
        guard !isScanning else { return }
        scanTask?.cancel()
        scanTask = Task { await performScan() }
    }

    private func performScan() async {
        isScanning = true
        scanDidFail = false
        startMessageRotation()

        let minimumDuration = Double.random(in: 1.0...3.0)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await self.manager.refreshDevices()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(minimumDuration * 1_000_000_000))
            }
            await group.waitForAll()
        }

        if Task.isCancelled {
            stopMessageRotation()
            isScanning = false
            return
        }

        stopMessageRotation()
        isScanning = false
        scanDidFail = false
        devices = manager.devices
        lastRefreshed = manager.lastRefreshed
    }

    private func startMessageRotation() {
        scanningStatusMessage = ScanningMessages.rotating.randomElement() ?? ScanningMessages.rotating[0]
        messageRotationTask?.cancel()
        messageRotationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    scanningStatusMessage = ScanningMessages.rotating.randomElement()
                        ?? ScanningMessages.rotating[0]
                }
            }
        }
    }

    private func stopMessageRotation() {
        messageRotationTask?.cancel()
        messageRotationTask = nil
    }

    func quit() {
        scanTask?.cancel()
        messageRotationTask?.cancel()
        NSApplication.shared.terminate(nil)
    }
}

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

/// Bridges `BluetoothManager` data into SwiftUI-friendly state and actions.
@MainActor
@Observable
final class BatteryViewModel {
    private let manager: BluetoothManager

    @ObservationIgnored
    private var devicesUpdateObserver: DevicesUpdateObserver?

    private(set) var devices: [BluetoothDevice] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshed: Date?

    var menuBarSymbolName: String {
        DeviceIcon.menuBarSymbol(lowestBattery: lowestBatteryPercent)
    }

    var isEmpty: Bool {
        devices.isEmpty
    }

    private var lowestBatteryPercent: Int? {
        devices.compactMap(\.batteryPercent).min()
    }

    var statusSubtitle: String {
        if isRefreshing { return "Refreshing…" }
        guard let lastRefreshed else { return "No scan yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: lastRefreshed, relativeTo: Date()))"
    }

    init(manager: BluetoothManager) {
        self.manager = manager
        syncFromManager()
        devicesUpdateObserver = DevicesUpdateObserver(manager: manager) { [weak self] in
            self?.syncFromManager()
        }
    }

    private func syncFromManager() {
        devices = manager.devices
        isRefreshing = manager.isRefreshing
        lastRefreshed = manager.lastRefreshed
    }

    func refresh() {
        manager.refresh()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}

//
//  BatteryViewModel.swift
//  ChargeLink
//

import AppKit
import Foundation
import Observation

/// Bridges `BluetoothManager` data into SwiftUI-friendly state and actions.
@MainActor
@Observable
final class BatteryViewModel {
    private let manager: BluetoothManager
    private nonisolated(unsafe) var updateObserver: NSObjectProtocol?

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
        updateObserver = NotificationCenter.default.addObserver(
            forName: .chargeLinkDevicesDidUpdate,
            object: manager,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.syncFromManager()
            }
        }
    }

    nonisolated deinit {
        if let updateObserver {
            NotificationCenter.default.removeObserver(updateObserver)
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

//
//  BluetoothPermissionManager.swift
//  ChargeLink
//

import CoreBluetooth
import Foundation

/// Triggers the system Bluetooth permission prompt (macOS 13+) via CoreBluetooth.
final class BluetoothPermissionManager: NSObject, CBCentralManagerDelegate {
    static let shared = BluetoothPermissionManager()

    private var centralManager: CBCentralManager?

    private override init() {
        super.init()
    }

    func requestAccessIfNeeded() {
        guard centralManager == nil else { return }
        BluetoothDebug.log("Requesting Bluetooth access via CBCentralManager…")
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        BluetoothDebug.log("CBCentralManager state: \(central.state.rawValue) (\(stateDescription(central.state)))")
    }

    private func stateDescription(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "other"
        }
    }
}

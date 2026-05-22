//
//  BluetoothDevice.swift
//  ChargeLink
//

import Foundation

/// A connected Bluetooth peripheral with an optional battery reading.
struct BluetoothDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String
    let batteryPercent: Int?
    /// Multi-part display (e.g. AirPods `L: 39% R: 56%`); falls back to `batteryPercent`.
    let batteryDetailText: String?
    /// When true, shows `battery.*.bolt` with pulse animation (if detected later).
    let isCharging: Bool
    let deviceClass: DeviceClass
    let isConnected: Bool

    enum DeviceClass: String, Sendable {
        case mouse
        case keyboard
        case trackpad
        case headphones
        case gameController
        case phone
        case wearable
        case peripheral
        case unknown
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address : trimmed
    }

    var batteryDisplay: String {
        if let batteryDetailText, !batteryDetailText.isEmpty {
            return batteryDetailText
        }
        guard let batteryPercent else { return "—" }
        return "\(batteryPercent)%"
    }

    var hasBatteryReading: Bool {
        batteryPercent != nil || !(batteryDetailText?.isEmpty ?? true)
    }

    var showsMultiPartBattery: Bool {
        guard let batteryDetailText else { return false }
        return batteryDetailText.contains("L:") || batteryDetailText.contains("R:") || batteryDetailText.contains("C:")
    }

    var symbolName: String {
        DeviceIcon.symbol(for: deviceClass)
    }
}

// MARK: - Device Icons

enum DeviceIcon {
    static func symbol(for deviceClass: BluetoothDevice.DeviceClass) -> String {
        switch deviceClass {
        case .mouse:
            return "computermouse.fill"
        case .keyboard:
            return "keyboard.fill"
        case .trackpad:
            return "trackpad"
        case .headphones:
            return "headphones"
        case .gameController:
            return "gamecontroller.fill"
        case .phone:
            return "iphone"
        case .wearable:
            return "applewatch"
        case .peripheral:
            return "bolt.horizontal.fill"
        case .unknown:
            return "antenna.radiowaves.left.and.right"
        }
    }

    static func menuBarSymbol(lowestBattery: Int?, isCharging: Bool = false) -> String {
        guard let lowestBattery else {
            return "bolt.horizontal.fill"
        }
        return BatteryIndicatorView.symbolName(percent: lowestBattery, charging: isCharging)
    }
}

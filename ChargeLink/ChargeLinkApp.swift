//
//  ChargeLinkApp.swift
//  ChargeLink
//

import SwiftUI

@main
struct ChargeLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = BatteryViewModel(manager: BluetoothManager.shared)

    var body: some Scene {
        MenuBarExtra {
            DeviceListView(viewModel: viewModel)
        } label: {
            MenuBarBatteryLabel(
                symbolName: viewModel.menuBarSymbolName,
                isCharging: viewModel.anyDeviceCharging
            )
        }
        .menuBarExtraStyle(.window)
    }
}

//
//  ChargeLinkApp.swift
//  ChargeLink
//

import SwiftUI

@main
struct ChargeLinkApp: App {
    @State private var viewModel = BatteryViewModel(manager: BluetoothManager.shared)

    var body: some Scene {
        MenuBarExtra {
            DeviceListView(viewModel: viewModel)
        } label: {
            Image(systemName: viewModel.menuBarSymbolName)
                .symbolRenderingMode(.hierarchical)
                .id(viewModel.menuBarSymbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

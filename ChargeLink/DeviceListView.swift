//
//  DeviceListView.swift
//  ChargeLink
//

import SwiftUI

struct DeviceListView: View {
    @Bindable var viewModel: BatteryViewModel

    private let popoverWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            deviceList
            Divider()
            footer
        }
        .frame(width: popoverWidth)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ChargeLink")
                .font(.headline)
            Text(viewModel.statusSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Device List

    @ViewBuilder
    private var deviceList: some View {
        if viewModel.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.devices) { device in
                        DeviceRowView(device: device)
                        if device.id != viewModel.devices.last?.id {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No connected Bluetooth devices")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isRefreshing)

            Spacer()

            Button(role: .destructive) {
                viewModel.quit()
            } label: {
                Text("Quit")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Device Row

private struct DeviceRowView: View {
    let device: BluetoothDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbolName)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 22, alignment: .center)
                .symbolRenderingMode(.hierarchical)

            Text(device.displayName)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            batteryLabel
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.displayName), battery \(device.batteryDisplay)")
    }

    @ViewBuilder
    private var batteryLabel: some View {
        if let percent = device.batteryPercent {
            HStack(spacing: 6) {
                BatteryGaugeView(percent: percent)
                Text("\(percent)%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(color(for: percent))
            }
        } else {
            Text("—")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    private func color(for percent: Int) -> Color {
        switch percent {
        case 21...100:
            return .primary
        case 11...20:
            return .orange
        default:
            return .red
        }
    }
}

// MARK: - Battery Gauge

private struct BatteryGaugeView: View {
    let percent: Int

    var body: some View {
        Image(systemName: gaugeSymbol)
            .font(.caption)
            .foregroundStyle(gaugeColor)
            .symbolRenderingMode(.palette)
    }

    private var gaugeSymbol: String {
        switch percent {
        case 81...100: return "battery.100"
        case 61...80: return "battery.75"
        case 41...60: return "battery.50"
        case 21...40: return "battery.25"
        default: return "battery.0"
        }
    }

    private var gaugeColor: Color {
        switch percent {
        case 21...100: return .green
        case 11...20: return .orange
        default: return .red
        }
    }
}

#Preview {
    DeviceListView(viewModel: BatteryViewModel())
        .padding()
}

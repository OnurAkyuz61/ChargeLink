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
            content
            Divider()
            footer
        }
        .frame(width: popoverWidth)
        .animation(.easeInOut(duration: 0.28), value: viewModel.isScanning)
        .animation(.easeInOut(duration: 0.28), value: viewModel.scanDidFail)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ChargeLink")
                .font(.headline)
            Text(viewModel.statusSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: viewModel.statusSubtitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .top) {
            if viewModel.isScanning {
                scanningPanel
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .bottom))
                    ))
            } else if viewModel.scanDidFail {
                errorState
                    .transition(.opacity.combined(with: .slide))
            } else {
                deviceList
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
            }
        }
        .frame(minHeight: 120)
    }

    private var scanningPanel: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)

            Text(viewModel.scanningStatusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: viewModel.scanningStatusMessage)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.06))
    }

    private var errorState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Hata")
                .font(.subheadline.weight(.semibold))
            Text("Tarama sırasında bir sorun oluştu. Lütfen tekrar deneyin.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

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
            Text("Bağlı Bluetooth cihazı yok")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Sistem Ayarları → Gizlilik ve Güvenlik → Bluetooth bölümünü kontrol edin.")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
                Label("Yenile", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isScanning)

            Spacer()

            Button(role: .destructive) {
                viewModel.quit()
            } label: {
                Text("Çıkış")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isScanning)
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
        .accessibilityLabel("\(device.displayName), pil \(device.batteryDisplay)")
    }

    @ViewBuilder
    private var batteryLabel: some View {
        if device.showsMultiPartBattery {
            Text(device.batteryDisplay)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        } else if let percent = device.batteryPercent {
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
    DeviceListView(viewModel: BatteryViewModel(manager: BluetoothManager.shared))
        .padding()
}

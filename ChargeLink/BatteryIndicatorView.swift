//
//  BatteryIndicatorView.swift
//  ChargeLink
//
//  Apple System Settings–style battery glyphs (SF Symbols + palette + charging animation).
//

import SwiftUI

// MARK: - Style

enum BatteryIndicatorStyle {
    case standard
    case compact
    case menuBar

    var iconFont: Font {
        switch self {
        case .standard: .body
        case .compact: .caption
        case .menuBar: .system(size: 13, weight: .medium)
        }
    }

    var percentFont: Font {
        switch self {
        case .standard: .subheadline.monospacedDigit()
        case .compact: .caption.monospacedDigit()
        case .menuBar: .caption2.monospacedDigit()
        }
    }

    var spacing: CGFloat {
        switch self {
        case .standard: 5
        case .compact: 4
        case .menuBar: 3
        }
    }
}

// MARK: - Single battery (Apple palette)

struct BatteryIndicatorView: View {
    let percent: Int
    var isCharging: Bool = false
    var style: BatteryIndicatorStyle = .standard
    var showsPercentText: Bool = true

    @State private var chargingPhase = false

    var body: some View {
        HStack(spacing: style.spacing) {
            batteryForeground
                .font(style.iconFont)
                .symbolRenderingMode(.palette)
                .symbolEffect(.bounce, options: .nonRepeating, value: percent)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.35), value: percent)
                .animation(.snappy(duration: 0.35), value: isCharging)

            if showsPercentText {
                Text("\(percent)%")
                    .font(style.percentFont)
                    .foregroundStyle(percentColor)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.35), value: percent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onAppear { updateChargingAnimation() }
        .onChange(of: isCharging) { _, _ in updateChargingAnimation() }
    }

    @ViewBuilder
    private var batterySymbol: some View {
        let name = Self.symbolName(percent: percent, charging: isCharging)
        if isCharging {
            Image(systemName: name)
                .symbolEffect(.pulse.byLayer, options: .repeating.speed(0.55), isActive: chargingPhase)
        } else {
            Image(systemName: name)
        }
    }

    @ViewBuilder
    private var batteryForeground: some View {
        if isCharging {
            batterySymbol
                .foregroundStyle(.primary.opacity(0.35), Color.accentColor)
        } else {
            batterySymbol
                .foregroundStyle(.primary.opacity(0.35), fillColor)
        }
    }

    private var fillColor: Color {
        switch percent {
        case 21...100: .green
        case 11...20: .orange
        default: .red
        }
    }

    private var percentColor: Color {
        if isCharging { return .accentColor }
        switch percent {
        case 21...100: return .primary
        case 11...20: return .orange
        default: return .red
        }
    }

    private var accessibilityText: String {
        if isCharging {
            return "Şarj oluyor, yüzde \(percent)"
        }
        return "Pil yüzde \(percent)"
    }

    private func updateChargingAnimation() {
        chargingPhase = isCharging
    }

    static func symbolName(percent: Int, charging: Bool) -> String {
        let level: String
        switch max(0, min(100, percent)) {
        case 95...100: level = "100"
        case 85..<95: level = "100"
        case 70..<85: level = "75"
        case 55..<70: level = "75"
        case 40..<55: level = "50"
        case 25..<40: level = "50"
        case 10..<25: level = "25"
        default: level = "0"
        }
        if charging {
            return "battery.\(level).bolt"
        }
        return "battery.\(level)"
    }
}

// MARK: - AirPods L / R / C row

struct AirPodsBatteryIndicatorView: View {
    let detailText: String
    var style: BatteryIndicatorStyle = .standard

    private var components: [(label: String, percent: Int)] {
        Self.parseComponents(from: detailText)
    }

    var body: some View {
        HStack(spacing: style == .compact ? 8 : 10) {
            ForEach(Array(components.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 3) {
                    Text(part.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    BatteryIndicatorView(
                        percent: part.percent,
                        style: .compact,
                        showsPercentText: true
                    )
                }
            }
        }
    }

    static func parseComponents(from text: String) -> [(String, Int)] {
        var results: [(String, Int)] = []
        let pattern = #"([LRC]):\s*(\d+)%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return results }
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 3,
                  let labelRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text),
                  let value = Int(text[valueRange]) else { return }
            let label = String(text[labelRange])
            let display: String
            switch label {
            case "L": display = "L"
            case "R": display = "R"
            case "C": display = "C"
            default: display = label
            }
            results.append((display, value))
        }
        return results
    }
}

// MARK: - Unknown battery

struct BatteryUnknownIndicatorView: View {
    var style: BatteryIndicatorStyle = .standard

    var body: some View {
        HStack(spacing: style.spacing) {
            Image(systemName: "battery.slash")
                .font(style.iconFont)
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text("—")
                .font(style.percentFont)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Menu bar label

struct MenuBarBatteryLabel: View {
    let symbolName: String
    let isCharging: Bool

    @State private var pulse = false

    var body: some View {
        Image(systemName: symbolName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.primary, isCharging ? Color.accentColor : Color.green)
            .symbolEffect(.pulse.byLayer, options: .repeating.speed(0.6), isActive: pulse && isCharging)
            .onAppear { pulse = isCharging }
            .onChange(of: isCharging) { _, charging in pulse = charging }
    }
}

#Preview("Levels") {
    VStack(alignment: .trailing, spacing: 12) {
        BatteryIndicatorView(percent: 100, isCharging: true)
        BatteryIndicatorView(percent: 50)
        BatteryIndicatorView(percent: 20)
        BatteryIndicatorView(percent: 8)
        AirPodsBatteryIndicatorView(detailText: "L: 97% R: 94% C: 32%")
        BatteryUnknownIndicatorView()
    }
    .padding()
    .frame(width: 280)
}

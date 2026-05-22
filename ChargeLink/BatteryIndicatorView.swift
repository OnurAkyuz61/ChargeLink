//
//  BatteryIndicatorView.swift
//  ChargeLink
//
//  macOS System Settings–style battery glyph (custom shape + şarj şimşeği).
//

import SwiftUI

// MARK: - App icon (sabit menü çubuğu)

enum ChargeLinkMenuBarIcon {
    static let symbolName = "bolt.horizontal.fill"
}

// MARK: - Style

enum BatteryIndicatorStyle {
    case standard
    case compact

    var bodyWidth: CGFloat {
        switch self {
        case .standard: 26
        case .compact: 22
        }
    }

    var bodyHeight: CGFloat {
        switch self {
        case .standard: 12
        case .compact: 10
        }
    }

    var percentFont: Font {
        switch self {
        case .standard: .subheadline.monospacedDigit()
        case .compact: .caption.monospacedDigit()
        }
    }

    var spacing: CGFloat {
        switch self {
        case .standard: 6
        case .compact: 4
        }
    }
}

// MARK: - Renkler (turuncu yok — düşük pil kırmızı)

enum BatteryLevelColors {
    static func fill(for percent: Int, isCharging: Bool) -> Color {
        if isCharging { return .green }
        if percent <= 20 { return .red }
        return .green
    }

    static func text(for percent: Int, isCharging: Bool) -> Color {
        if isCharging { return .green }
        if percent <= 20 { return .red }
        return .primary
    }
}

// MARK: - Custom battery shape (Apple benzeri)

private struct MacBatteryIcon: View {
    let percent: Int
    let isCharging: Bool
    let style: BatteryIndicatorStyle

    @State private var boltPulse = false

    private var fillFraction: CGFloat {
        CGFloat(max(0, min(100, percent))) / 100
    }

    private var fillColor: Color {
        BatteryLevelColors.fill(for: percent, isCharging: isCharging)
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.32), lineWidth: 1)

                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(fillColor)
                    .padding(2)
                    .frame(
                        width: max(3, (style.bodyWidth - 4) * fillFraction),
                        alignment: .leading
                    )
                    .animation(.snappy(duration: 0.35), value: percent)

                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: style == .compact ? 6 : 7, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(boltPulse ? 1.08 : 0.92)
                        .animation(
                            .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                            value: boltPulse
                        )
                }
            }
            .frame(width: style.bodyWidth, height: style.bodyHeight)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.primary.opacity(0.32))
                .frame(width: 2, height: style.bodyHeight * 0.42)
        }
        .onAppear {
            boltPulse = isCharging
        }
        .onChange(of: isCharging) { _, charging in
            boltPulse = charging
        }
    }
}

// MARK: - Row indicator

struct BatteryIndicatorView: View {
    let percent: Int
    var isCharging: Bool = false
    var style: BatteryIndicatorStyle = .standard
    var showsPercentText: Bool = true

    var body: some View {
        HStack(spacing: style.spacing) {
            MacBatteryIcon(percent: percent, isCharging: isCharging, style: style)

            if showsPercentText {
                HStack(spacing: 2) {
                    if isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                    }
                    Text("\(percent)%")
                        .font(style.percentFont)
                        .foregroundStyle(BatteryLevelColors.text(for: percent, isCharging: isCharging))
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.35), value: percent)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCharging ? "Şarj oluyor, yüzde \(percent)" : "Pil yüzde \(percent)")
    }
}

// MARK: - AirPods L / R / C

struct AirPodsBatteryIndicatorView: View {
    let detailText: String
    var chargingParts: Set<String> = []
    var style: BatteryIndicatorStyle = .standard

    private var components: [(label: String, percent: Int)] {
        Self.parseComponents(from: detailText)
    }

    var body: some View {
        HStack(spacing: style == .compact ? 8 : 10) {
            ForEach(Array(components.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 3) {
                    Text(part.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    BatteryIndicatorView(
                        percent: part.percent,
                        isCharging: chargingParts.contains(part.label),
                        style: .compact
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
            results.append((String(text[labelRange]), value))
        }
        return results
    }
}

// MARK: - Unknown

struct BatteryUnknownIndicatorView: View {
    var style: BatteryIndicatorStyle = .standard

    var body: some View {
        HStack(spacing: style.spacing) {
            Image(systemName: "minus.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("—")
                .font(style.percentFont)
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    VStack(alignment: .trailing, spacing: 14) {
        BatteryIndicatorView(percent: 50)
        BatteryIndicatorView(percent: 15)
        BatteryIndicatorView(percent: 72, isCharging: true)
        AirPodsBatteryIndicatorView(detailText: "L: 97% R: 94% C: 32%", chargingParts: ["C"])
    }
    .padding()
    .frame(width: 300)
}

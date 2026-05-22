//
//  BatteryReading.swift
//  ChargeLink
//

import Foundation

/// Unified battery result from BLE / IORegistry / IOHID subsystems.
struct BatteryReading: Equatable, Sendable {
    let percent: Int?
    let detailText: String?
    let isCharging: Bool
    let source: String

    init(
        percent: Int?,
        detailText: String?,
        isCharging: Bool = false,
        source: String
    ) {
        self.percent = percent
        self.detailText = detailText
        self.isCharging = isCharging
        self.source = source
    }

    static let unknown = BatteryReading(percent: nil, detailText: nil, isCharging: false, source: "none")

    var hasValue: Bool {
        percent != nil || !(detailText?.isEmpty ?? true)
    }

    var displayText: String {
        if let detailText, !detailText.isEmpty { return detailText }
        guard let percent else { return "—" }
        return "\(percent)%"
    }

    /// Lower `priority` value wins when merging candidates.
    func withPriority(_ priority: Int) -> PrioritizedBatteryReading {
        PrioritizedBatteryReading(reading: self, priority: priority)
    }
}

struct PrioritizedBatteryReading {
    let reading: BatteryReading
    let priority: Int

    static func selectBest(from candidates: [PrioritizedBatteryReading]) -> BatteryReading? {
        candidates.min(by: { $0.priority < $1.priority })?.reading
    }
}

// MARK: - AirPods multi-battery

struct AirPodsBatteryComponents: Equatable, Sendable {
    var left: Int?
    var right: Int?
    var casePercent: Int?
    var single: Int?

    var hasAnyValue: Bool {
        left != nil || right != nil || casePercent != nil || single != nil
    }

    var primaryPercent: Int? {
        let values = [left, right, casePercent, single].compactMap { $0 }
        return values.min()
    }

    var detailText: String {
        var parts: [String] = []
        if let left { parts.append("L: \(left)%") }
        if let right { parts.append("R: \(right)%") }
        if let casePercent { parts.append("C: \(casePercent)%") }
        if parts.isEmpty, let single { return "\(single)%" }
        return parts.joined(separator: " ")
    }

    func asReading(source: String) -> BatteryReading? {
        guard hasAnyValue else { return nil }
        return BatteryReading(
            percent: primaryPercent,
            detailText: detailText,
            isCharging: false,
            source: source
        )
    }
}

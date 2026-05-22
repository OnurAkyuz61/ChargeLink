//
//  BatteryChargingTrendTracker.swift
//  ChargeLink
//
//  Heuristic charging detection when hardware does not expose a charging flag
//  (common for Logitech BLE peripherals on macOS).
//

import Foundation

/// Tracks recent battery % samples and infers charging when level rises between refreshes.
enum BatteryChargingTrendTracker {
    private struct Sample: Codable {
        let percent: Int
        let date: Date
    }

    private static let defaultsKey = "ChargeLink.BatteryChargingTrend"
    private static let chargingTTL: TimeInterval = 45 * 60
    private static let minRisePoints = 1

    private static var memory: [String: Sample] = [:]

    static func isCharging(deviceKey: String, currentPercent: Int) -> Bool {
        let key = DeviceNameMatcher.normalize(deviceKey)
        guard !key.isEmpty, (1...100).contains(currentPercent) else { return false }

        let now = Date()
        let previous = memory[key] ?? loadPersisted(key: key)

        defer {
            memory[key] = Sample(percent: currentPercent, date: now)
            persist(key: key, sample: memory[key]!)
        }

        guard let previous else { return false }

        if now.timeIntervalSince(previous.date) > chargingTTL {
            return false
        }

        let delta = currentPercent - previous.percent
        return delta >= minRisePoints
    }

    static func markCharging(deviceKey: String, currentPercent: Int) {
        let key = DeviceNameMatcher.normalize(deviceKey)
        guard !key.isEmpty else { return }
        let sample = Sample(percent: currentPercent, date: Date())
        memory[key] = sample
        persist(key: key, sample: sample)
    }

    private static func loadPersisted(key: String) -> Sample? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode([String: Sample].self, from: data) else {
            return nil
        }
        return map[key]
    }

    private static func persist(key: String, sample: Sample) {
        var map = (try? JSONDecoder().decode(
            [String: Sample].self,
            from: UserDefaults.standard.data(forKey: defaultsKey) ?? Data()
        )) ?? [:]
        map[key] = sample
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

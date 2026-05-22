//
//  BLEReading.swift
//  ChargeLink
//

import Foundation

struct BLEReading: Equatable, Sendable {
    let percent: Int
    let isCharging: Bool
}

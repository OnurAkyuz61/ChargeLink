//
//  Item.swift
//  ChargeLink
//
//  Created by Onur Akyüz on 22.05.2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

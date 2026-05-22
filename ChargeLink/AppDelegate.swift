//
//  AppDelegate.swift
//  ChargeLink
//

import AppKit

/// Menu-bar-only activation policy (no dock icon, no startup window).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

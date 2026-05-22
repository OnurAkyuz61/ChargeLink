//
//  AppDelegate.swift
//  ChargeLink
//

import AppKit
import SwiftUI

/// Owns the menu bar status item and popover (reliable vs. SwiftUI-only MenuBarExtra).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel: BatteryViewModel

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var iconUpdateObserver: NSObjectProtocol?

    override init() {
        viewModel = BatteryViewModel(manager: BluetoothManager.shared)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        closeLaunchWindows()
        setupStatusItem()
        observeIconUpdates()
        updateStatusIcon()
    }

    /// Hides the placeholder `WindowGroup` on macOS 14 (no `.defaultLaunchBehavior(.suppressed)`).
    private func closeLaunchWindows() {
        for window in NSApp.windows {
            window.orderOut(nil)
            window.close()
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            BluetoothDebug.log("Failed to create NSStatusItem button")
            return
        }

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "ChargeLink"

        statusItem = item
        BluetoothDebug.log("Menu bar status item created")
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu(on: button)
            return
        }

        togglePopover(on: button)
    }

    private func togglePopover(on button: NSStatusBarButton) {
        setupPopoverIfNeeded()
        guard let popover else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func setupPopoverIfNeeded() {
        guard popover == nil else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 380)
        popover.contentViewController = NSHostingController(
            rootView: DeviceListView(viewModel: viewModel)
        )
        self.popover = popover
    }

    private func showContextMenu(on button: NSStatusBarButton) {
        let menu = NSMenu()
        let refreshItem = NSMenuItem(
            title: "Refresh",
            action: #selector(refreshFromMenu),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit ChargeLink",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func refreshFromMenu() {
        viewModel.refresh()
        updateStatusIcon()
    }

    @objc private func quitFromMenu() {
        viewModel.quit()
    }

    // MARK: - Dynamic icon

    private func observeIconUpdates() {
        iconUpdateObserver = NotificationCenter.default.addObserver(
            forName: .chargeLinkDevicesDidUpdate,
            object: BluetoothManager.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusIcon()
            }
        }
    }

    private func updateStatusIcon() {
        let symbolName = viewModel.menuBarSymbolName
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ChargeLink") else {
            BluetoothDebug.log("Could not load SF Symbol: \(symbolName)")
            return
        }
        image.isTemplate = true
        statusItem?.button?.image = image
    }

    deinit {
        if let iconUpdateObserver {
            NotificationCenter.default.removeObserver(iconUpdateObserver)
        }
    }
}

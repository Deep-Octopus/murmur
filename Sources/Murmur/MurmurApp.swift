import AppKit
import SwiftUI

@main
struct MurmurMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: MessageStore!
    private var panelController: FloatingPanelController!
    private var userNotedWatcher: UserNotedWatcher!
    private var axBridge: AccessibilityBridge!
    private var statusItem: NSStatusItem!
    private var appActivationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = MessageStore()
        panelController = FloatingPanelController(store: store)

        axBridge = AccessibilityBridge(initialApps: store.monitoredApps) { [weak self] observation in
            self?.store.reconcileAXObservation(observation)
        }

        userNotedWatcher = UserNotedWatcher(
            initialApps: store.monitoredApps,
            onNotifications: { [weak self] rawList, isStartup in
                self?.store.ingestNotifications(rawList, isStartupBackfill: isStartup)
            },
            onStateChanged: { [weak self] state in
                self?.store.notificationReaderState = state
            }
        )

        store.onMonitoredAppsChanged = { [weak self] updatedApps in
            self?.axBridge.updateMonitoredApps(updatedApps)
            self?.userNotedWatcher.updateMonitoredApps(updatedApps)
        }

        store.onJumpRequested = { [weak self] item, monitoredApp in
            guard let self else { return .appActivatedNeedsConfirm }
            let result = self.axBridge.jumpToItem(item, app: monitoredApp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.axBridge.triggerScan()
            }
            return result
        }

        store.onOpenAppRequested = { [weak self] monitoredApp in
            self?.axBridge.openAppDirectly(monitoredApp)
        }

        setupMenuBarItem()
        panelController.show()

        axBridge.startPolling()
        userNotedWatcher.start()

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.axBridge.triggerScan()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        axBridge?.stopPolling()
        userNotedWatcher?.stop()
        if let obs = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "tray.and.arrow.down",
                accessibilityDescription: "Murmur"
            )
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let built = panelController.buildControlMenu()
        while !built.items.isEmpty {
            let item = built.items[0]
            built.removeItem(at: 0)
            menu.addItem(item)
        }
    }
}

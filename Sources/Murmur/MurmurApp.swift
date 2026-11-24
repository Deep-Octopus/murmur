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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MessageStore!
    private var panelController: FloatingPanelController!
    private var userNotedWatcher: UserNotedWatcher!
    private var axBridge: AccessibilityBridge!
    private var statusItem: NSStatusItem!
    private var appActivationObserver: NSObjectProtocol?
    private var didStartUserNotedWatcher = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = MessageStore()
        panelController = FloatingPanelController(store: store)

        userNotedWatcher = UserNotedWatcher(
            initialApps: store.monitoredApps,
            onNotifications: { [weak self] rawList, isStartup in
                self?.store.ingestNotifications(rawList, isStartupBackfill: isStartup)
            },
            onStateChanged: { [weak self] state in
                self?.store.notificationReaderState = state
            }
        )

        axBridge = AccessibilityBridge(initialApps: store.monitoredApps) { [weak self] observation in
            guard let self else { return }
            self.store.reconcileAXObservation(observation)
            self.startUserNotedWatcherOnce()
        }

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

        store.onStatusItemNeedsUpdate = { [weak self] in
            self?.refreshStatusBarAppearance()
        }

        setupMenuBarItem()
        refreshStatusBarAppearance()
        panelController.show()

        // Run initial AX/Dock ground-truth scan BEFORE starting notification backfill
        axBridge.startPolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.startUserNotedWatcherOnce()
        }

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

    private func startUserNotedWatcherOnce() {
        guard !didStartUserNotedWatcher else { return }
        didStartUserNotedWatcher = true
        userNotedWatcher.start()
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
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleStatusBarButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Murmur — 左键展开待办队列，右键打开快捷菜单"
    }

    private func refreshStatusBarAppearance() {
        guard let button = statusItem?.button else { return }
        let count = store.pendingItemCount
        let symbolName: String
        if store.isPeeksPaused {
            symbolName = "moon.fill"
        } else if count > 0 {
            symbolName = "tray.full.fill"
        } else {
            symbolName = "tray.and.arrow.down"
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Murmur")
        if count > 0 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.attributedTitle = NSAttributedString(
                string: " \(count)",
                attributes: [.font: font]
            )
        } else {
            button.title = ""
        }
    }

    @objc private func handleStatusBarButtonClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = (event?.type == .rightMouseUp) || (event?.modifierFlags.contains(.control) == true)

        if isRightClick {
            let menu = panelController.buildControlMenu()
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            panelController.handleStatusBarLeftClick()
        }
    }
}

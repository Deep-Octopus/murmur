import AppKit
import Carbon
import QuartzCore
import SwiftUI

final class NonActivatingPanel: NSPanel {
    var allowBecomeKey: Bool = false
    override var canBecomeKey: Bool { allowBecomeKey }
    override var canBecomeMain: Bool { false }
}

private var sharedHotKeyCallback: (() -> Void)?

private func carbonHotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        sharedHotKeyCallback?()
    }
    return noErr
}

@MainActor
final class FloatingPanelController: NSObject {
    let panel: NonActivatingPanel
    private let store: MessageStore
    private var hostingView: NSHostingView<OrbRootView>!
    private var eventMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    private var anchorX: CGFloat = 0
    private var anchorY: CGFloat = 0
    private(set) var alignRight: Bool = true
    private(set) var alignTop: Bool = true

    private var pendingLayoutUpdate = false
    private var pendingAnimateFlag = false
    private var isDraggingWindow = false
    private var dragCandidateActive = false
    private var mouseDownScreenPoint: NSPoint = .zero
    private var mouseDownAnchor: NSPoint = .zero

    init(store: MessageStore) {
        self.store = store

        let initialRect = NSRect(x: 100, y: 100, width: 64, height: 64)
        self.panel = NonActivatingPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false

        restoreOrPlaceInitialAnchor()
        applyWindowConfig(bringToFront: true)

        let rootView = OrbRootView(store: store)
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.frame = initialRect
        panel.contentView = hosting
        self.hostingView = hosting

        store.onLayoutNeedsUpdate = { [weak self] animated in
            guard let self else { return }
            if !self.store.isExpanded && self.panel.allowBecomeKey {
                self.panel.allowBecomeKey = false
                self.panel.resignKey()
            }
            self.scheduleFrameUpdate(animated: animated)
        }
        store.onWindowConfigChanged = { [weak self] in
            self?.applyWindowConfig(bringToFront: true)
        }
        store.onHotkeySettingChanged = { [weak self] enabled in
            self?.applyGlobalHotKey(enabled: enabled)
        }
        store.onSnapCornerRequested = { [weak self] corner in
            self?.snapToActiveScreen(corner: corner)
        }

        installEventMonitors()
        observeScreenChanges()
        applyGlobalHotKey(enabled: store.enableGlobalHotkey)
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
        }
        if let hh = hotKeyHandlerRef {
            RemoveEventHandler(hh)
        }
    }

    // MARK: - Carbon Global HotKey (`⌥ Option + M` — Zero Input Monitoring TCC Prompt!)

    func applyGlobalHotKey(enabled: Bool) {
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
            hotKeyRef = nil
        }

        guard enabled else { return }

        if hotKeyHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                carbonHotKeyHandler,
                1,
                &eventType,
                nil,
                &hotKeyHandlerRef
            )
        }

        sharedHotKeyCallback = { [weak self] in
            self?.toggleViaKeyboardSession()
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4F5242), id: 1) // 'MORB'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func toggleViaKeyboardSession() {
        if store.isExpanded {
            panel.allowBecomeKey = false
            panel.resignKey()
            store.collapsePanel()
        } else {
            store.toggleExpanded()
            panel.allowBecomeKey = true
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    // MARK: - Multi-Monitor Normalized Persistence & Edge Clamping

    private static func screenUUID(for screen: NSScreen) -> String {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "\(num.uint32Value)"
        }
        return "\(Int(screen.frame.origin.x))_\(Int(screen.frame.origin.y))"
    }

    private static func activeCursorScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let match = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return match
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func targetScreenForAnchor() -> NSScreen? {
        let pt = CGPoint(x: anchorX, y: anchorY)
        if let exact = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -24, dy: -24).contains(pt) }) {
            return exact
        }
        if let savedUUID = UserDefaults.standard.string(forKey: "orbDisplayUUID"),
           let matched = NSScreen.screens.first(where: { Self.screenUUID(for: $0) == savedUUID }) {
            return matched
        }
        return Self.activeCursorScreen()
    }

    private func restoreOrPlaceInitialAnchor() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "orbUserHasPlaced"),
           let savedUUID = defaults.string(forKey: "orbDisplayUUID"),
           let screen = NSScreen.screens.first(where: { Self.screenUUID(for: $0) == savedUUID }) {
            let normX = CGFloat(defaults.double(forKey: "orbNormX"))
            let normY = CGFloat(defaults.double(forKey: "orbNormY"))
            let vf = screen.visibleFrame
            anchorX = vf.minX + normX * vf.width
            anchorY = vf.minY + normY * vf.height
            recomputeAlignment(in: screen)
            return
        }

        if defaults.bool(forKey: "orbUserHasPlaced"),
           let sx = defaults.object(forKey: "orbAnchorX") as? Double,
           let sy = defaults.object(forKey: "orbAnchorY") as? Double {
            let pt = CGPoint(x: sx, y: sy)
            if let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -30, dy: -30).contains(pt) }) {
                anchorX = CGFloat(sx)
                anchorY = CGFloat(sy)
                recomputeAlignment(in: screen)
                persistAnchor(markUserPlaced: true)
                return
            }
        }

        let screen = Self.activeCursorScreen()
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        anchorX = vf.maxX - 20
        anchorY = vf.maxY - 16
        recomputeAlignment(in: screen)
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.restoreOrPlaceInitialAnchor()
                self.scheduleFrameUpdate(animated: false)
            }
        }
    }

    func snapToActiveScreen(corner: ScreenCorner) {
        let screen = Self.activeCursorScreen()
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let padX: CGFloat = 20
        let padY: CGFloat = 16

        switch corner {
        case .topRight:
            anchorX = vf.maxX - padX
            anchorY = vf.maxY - padY
        case .bottomRight:
            anchorX = vf.maxX - padX
            anchorY = vf.minY + padY
        case .topLeft:
            anchorX = vf.minX + padX
            anchorY = vf.maxY - padY
        case .bottomLeft:
            anchorX = vf.minX + padX
            anchorY = vf.minY + padY
        }

        recomputeAlignment(in: screen)
        persistAnchor(markUserPlaced: true)
        scheduleFrameUpdate(animated: true)
        panel.orderFrontRegardless()
    }

    func applyWindowConfig(bringToFront: Bool) {
        switch store.windowLevelMode {
        case .alwaysOnTop:
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        case .desktopFloating:
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        case .normal:
            panel.isFloatingPanel = false
            panel.level = .normal
            panel.collectionBehavior = [.moveToActiveSpace]
        }
        if bringToFront {
            panel.orderFrontRegardless()
        }
    }

    func show() {
        performFrameUpdateNow(animated: false)
        panel.orderFrontRegardless()
    }

    // MARK: - Coalesced Smooth Spring Morphing

    func scheduleFrameUpdate(animated: Bool) {
        if animated { pendingAnimateFlag = true }
        guard !pendingLayoutUpdate else { return }
        pendingLayoutUpdate = true

        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            let shouldAnimate = self.pendingAnimateFlag
            self.pendingLayoutUpdate = false
            self.pendingAnimateFlag = false
            self.performFrameUpdateNow(animated: shouldAnimate)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func performFrameUpdateNow(animated: Bool) {
        guard !isDraggingWindow else { return }
        hostingView.layoutSubtreeIfNeeded()
        let intrinsic = hostingView.intrinsicContentSize
        let rawW = intrinsic.width > 0 ? intrinsic.width : hostingView.fittingSize.width
        let rawH = intrinsic.height > 0 ? intrinsic.height : hostingView.fittingSize.height
        let width = max(48, ceil(rawW))
        let height = max(48, ceil(rawH))

        var originX = alignRight ? round(anchorX - width) : round(anchorX)
        var originY = alignTop ? round(anchorY - height) : round(anchorY)

        if let screen = targetScreenForAnchor() {
            let vf = screen.visibleFrame.insetBy(dx: 6, dy: 6)
            originX = min(max(originX, vf.minX), max(vf.minX, vf.maxX - width))
            originY = min(max(originY, vf.minY), max(vf.minY, vf.maxY - height))
        }

        let targetFrame = NSRect(x: originX, y: originY, width: width, height: height)
        guard panel.frame != targetFrame else { return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduceMotion && panel.isVisible {
            hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = store.isExpanded ? 0.25 : 0.20
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true, animate: false)
            hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
    }

    // MARK: - Pointer Drag, Keyboard Triage & Context Menu

    private func installEventMonitors() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                return self.handleKeyDown(event)
            }
            guard event.window === self.panel else { return event }
            return self.handlePanelMouseEvent(event)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard store.isExpanded else { return event }

        switch event.keyCode {
        case 53: // Esc
            panel.allowBecomeKey = false
            panel.resignKey()
            store.collapsePanel()
            return nil
        case 125: // Down arrow
            if !store.showSettings {
                store.moveKeyboardSelection(delta: 1)
                return nil
            }
        case 126: // Up arrow
            if !store.showSettings {
                store.moveKeyboardSelection(delta: -1)
                return nil
            }
        case 36, 76: // Return / Enter
            if !store.showSettings {
                panel.allowBecomeKey = false
                panel.resignKey()
                store.triggerKeyboardOpen()
                return nil
            }
        case 51: // Delete / Backspace -> mark selected completed
            if !store.showSettings {
                store.triggerKeyboardComplete()
                return nil
            }
        case 1: // 'S' -> snooze 15m
            if !store.showSettings, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                store.triggerKeyboardSnooze()
                return nil
            }
        default:
            break
        }
        return event
    }

    private func handlePanelMouseEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .rightMouseDown:
            // Only pop panel-level menu on compact orb or header; let rows handle their own SwiftUI contextMenu!
            let loc = event.locationInWindow
            if store.surfaceMode == .compact || loc.y >= panel.frame.height - 48 {
                let menu = buildControlMenu()
                NSMenu.popUpContextMenu(menu, with: event, for: hostingView)
                return nil
            }
            return event

        case .leftMouseDown:
            let loc = event.locationInWindow
            let winSize = panel.frame.size

            let isCompact = (store.surfaceMode == .compact)
            if isCompact {
                store.isOrbPressed = true
            }

            let inTopHeaderDragStrip = (loc.y >= winSize.height - 48) && (loc.x < winSize.width - 120)
            let optionHeld = event.modifierFlags.contains(.option)
            let canDrag = (!store.lockOrbPosition || optionHeld) && (isCompact || inTopHeaderDragStrip)

            if canDrag {
                dragCandidateActive = true
                isDraggingWindow = false
                mouseDownScreenPoint = NSEvent.mouseLocation
                mouseDownAnchor = NSPoint(x: anchorX, y: anchorY)
            } else {
                dragCandidateActive = false
                isDraggingWindow = false
            }
            return event

        case .leftMouseDragged:
            guard dragCandidateActive else { return event }
            let cur = NSEvent.mouseLocation
            let dx = cur.x - mouseDownScreenPoint.x
            let dy = cur.y - mouseDownScreenPoint.y

            if !isDraggingWindow && hypot(dx, dy) >= 4.0 {
                isDraggingWindow = true
                store.isOrbPressed = false
            }

            if isDraggingWindow {
                anchorX = mouseDownAnchor.x + dx
                anchorY = mouseDownAnchor.y + dy

                let activeScreen = Self.activeCursorScreen()
                if let vf = activeScreen?.visibleFrame {
                    anchorX = min(max(anchorX, vf.minX + 16), vf.maxX - 8)
                    anchorY = min(max(anchorY, vf.minY + 16), vf.maxY - 8)
                }

                let w = panel.frame.width
                let h = panel.frame.height
                let ox = alignRight ? round(anchorX - w) : round(anchorX)
                let oy = alignTop ? round(anchorY - h) : round(anchorY)
                panel.setFrameOrigin(NSPoint(x: ox, y: oy))
                return nil
            }
            return event

        case .leftMouseUp:
            store.isOrbPressed = false
            let wasDragging = isDraggingWindow
            dragCandidateActive = false
            isDraggingWindow = false

            if wasDragging {
                let pointerScreen = Self.activeCursorScreen()
                let prevRight = alignRight
                let prevTop = alignTop
                recomputeAlignment(in: pointerScreen)

                if prevRight != alignRight || prevTop != alignTop {
                    let f = panel.frame
                    anchorX = alignRight ? f.maxX : f.minX
                    anchorY = alignTop ? f.maxY : f.minY
                }
                persistAnchor(markUserPlaced: true, in: pointerScreen)
                scheduleFrameUpdate(animated: true)
                return nil
            }
            return event

        default:
            return event
        }
    }

    private func recomputeAlignment(in screen: NSScreen?) {
        let target = screen ?? targetScreenForAnchor()
        let midX = target?.frame.midX ?? 720
        let midY = target?.frame.midY ?? 450
        alignRight = anchorX >= midX
        alignTop = anchorY >= midY
        UserDefaults.standard.set(alignRight, forKey: "orbAlignRight")
        UserDefaults.standard.set(alignTop, forKey: "orbAlignTop")
    }

    private func persistAnchor(markUserPlaced: Bool, in explicitScreen: NSScreen? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(Double(anchorX), forKey: "orbAnchorX")
        defaults.set(Double(anchorY), forKey: "orbAnchorY")

        if let screen = explicitScreen ?? targetScreenForAnchor() {
            let vf = screen.visibleFrame
            let nx = vf.width > 0 ? min(max((anchorX - vf.minX) / vf.width, 0), 1) : 0.98
            let ny = vf.height > 0 ? min(max((anchorY - vf.minY) / vf.height, 0), 1) : 0.98
            defaults.set(Self.screenUUID(for: screen), forKey: "orbDisplayUUID")
            defaults.set(Double(nx), forKey: "orbNormX")
            defaults.set(Double(ny), forKey: "orbNormY")
        }

        if markUserPlaced {
            defaults.set(true, forKey: "orbUserHasPlaced")
        }
    }

    // MARK: - Control Menu

    func buildControlMenu() -> NSMenu {
        let menu = NSMenu()

        let toggleTitle = store.enableGlobalHotkey
            ? (store.isExpanded ? "收起待处理列表 (⌥M)" : "展开待处理列表 (⌥M)")
            : (store.isExpanded ? "收起待处理列表" : "展开待处理列表")
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(menuToggleExpanded), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let appsItem = NSMenuItem(title: "添加 / 管理监控软件...", action: #selector(menuOpenAppsManager), keyEquivalent: "")
        appsItem.target = self
        menu.addItem(appsItem)

        let settingsItem = NSMenuItem(title: "偏好与设置...", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Focus / Meeting Pause
        if store.isPeeksPaused {
            let resumeItem = NSMenuItem(title: "✓ 免弹窗专注中 — 点击恢复弹窗", action: #selector(menuResumePeeks), keyEquivalent: "")
            resumeItem.target = self
            menu.addItem(resumeItem)
        } else {
            let pauseSub = NSMenu()
            for (label, mins) in [("暂停弹窗 30 分钟（会议/演示）", 30), ("暂停弹窗 1 小时", 60), ("暂停弹窗 2 小时", 120)] {
                let it = NSMenuItem(title: label, action: #selector(menuPausePeeks(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = mins
                pauseSub.addItem(it)
            }
            let pauseParent = NSMenuItem(title: "会议免弹窗模式", action: nil, keyEquivalent: "")
            pauseParent.submenu = pauseSub
            menu.addItem(pauseParent)
        }

        // Window Level
        let levelSub = NSMenu()
        for mode in WindowLevelMode.allCases {
            let item = NSMenuItem(title: "\(mode.displayName) — \(mode.subtitle)", action: #selector(menuSelectLevel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (store.windowLevelMode == mode) ? .on : .off
            levelSub.addItem(item)
        }
        let levelParent = NSMenuItem(title: "置顶层级", action: nil, keyEquivalent: "")
        levelParent.submenu = levelSub
        menu.addItem(levelParent)

        // Size presets
        let scaleSub = NSMenu()
        for (label, val) in [("紧凑 (85%)", 0.85), ("标准 (100%)", 1.00), ("舒适 (115%)", 1.15), ("醒目 (135%)", 1.35), ("大号 (155%)", 1.55)] {
            let item = NSMenuItem(title: label, action: #selector(menuSelectScale(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = val
            item.state = (abs(store.orbScale - val) < 0.06) ? .on : .off
            scaleSub.addItem(item)
        }
        let scaleParent = NSMenuItem(title: "尺寸大小", action: nil, keyEquivalent: "")
        scaleParent.submenu = scaleSub
        menu.addItem(scaleParent)

        // Appearance
        let themeSub = NSMenu()
        for mode in AppearanceMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(menuSelectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (store.appearanceMode == mode) ? .on : .off
            themeSub.addItem(item)
        }
        let themeParent = NSMenuItem(title: "外观色调", action: nil, keyEquivalent: "")
        themeParent.submenu = themeSub
        menu.addItem(themeParent)

        let lockItem = NSMenuItem(
            title: "锁定位置（按住 ⌥ 可临时拖动）",
            action: #selector(menuToggleLock),
            keyEquivalent: ""
        )
        lockItem.target = self
        lockItem.state = store.lockOrbPosition ? .on : .off
        menu.addItem(lockItem)

        let cornerSub = NSMenu()
        for corner in ScreenCorner.allCases {
            let item = NSMenuItem(title: "移至当前屏幕 · \(corner.rawValue)", action: #selector(menuSnapCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = corner.rawValue
            cornerSub.addItem(item)
        }
        let cornerParent = NSMenuItem(title: "找回 / 停靠到当前屏幕", action: nil, keyEquivalent: "")
        cornerParent.submenu = cornerSub
        menu.addItem(cornerParent)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Murmur", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func menuToggleExpanded() {
        store.toggleExpanded()
        panel.orderFrontRegardless()
    }

    @objc private func menuOpenAppsManager() {
        store.isExpanded = true
        store.showSettings = true
        store.settingsTab = 0
        scheduleFrameUpdate(animated: true)
        panel.orderFrontRegardless()
    }

    @objc private func menuOpenSettings() {
        store.isExpanded = true
        store.showSettings = true
        store.settingsTab = 1
        scheduleFrameUpdate(animated: true)
        panel.orderFrontRegardless()
    }

    @objc private func menuPausePeeks(_ sender: NSMenuItem) {
        guard let mins = sender.representedObject as? Int else { return }
        store.pausePeeks(minutes: mins)
    }

    @objc private func menuResumePeeks() {
        store.pausePeeks(minutes: 0)
    }

    @objc private func menuSelectLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WindowLevelMode(rawValue: raw) else { return }
        store.windowLevelMode = mode
    }

    @objc private func menuSelectScale(_ sender: NSMenuItem) {
        guard let val = sender.representedObject as? Double else { return }
        store.orbScale = val
        scheduleFrameUpdate(animated: true)
    }

    @objc private func menuSelectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AppearanceMode(rawValue: raw) else { return }
        store.appearanceMode = mode
    }

    @objc private func menuToggleLock() {
        store.lockOrbPosition.toggle()
    }

    @objc private func menuSnapCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let corner = ScreenCorner(rawValue: raw) else { return }
        snapToActiveScreen(corner: corner)
    }

    @objc private func menuQuit() {
        NSApplication.shared.terminate(nil)
    }
}

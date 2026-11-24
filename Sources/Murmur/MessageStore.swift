import Foundation
import ServiceManagement
import SwiftUI

struct UndoSnapshot {
    let item: MessageItem
    let mutedRule: MutedConversationRule?
    let label: String
}

private struct PersistedQueueState: Codable {
    var items: [MessageItem]
    var handledRevisions: [String: String]
    var seenNotificationKeys: [String]
    var mutedRules: [MutedConversationRule]
}

@MainActor
final class MessageStore: ObservableObject {
    @Published var monitoredApps: [MonitoredApp] = MonitoredApp.defaultApps
    @Published var items: [MessageItem] = []
    @Published var mutedRules: [MutedConversationRule] = []

    @Published var isExpanded: Bool = false
    @Published var showSettings: Bool = false
    @Published var showSnoozedSheet: Bool = false
    @Published var selectedFilterAppId: String? = nil
    @Published var activePeek: PeekPayload? = nil
    @Published var undoBanner: UndoSnapshot? = nil
    @Published var transientNotice: String? = nil
    @Published var pausePeeksUntil: Date? = nil

    @Published var now: Date = Date()
    @Published var dockBadges: [String: DockBadgeReading] = [:]
    @Published var hasAccessibilityPermission: Bool = true
    @Published var notificationReaderState: NotificationReaderState = .checking

    // UI & Keyboard interaction states
    @Published var isOrbHovering: Bool = false
    @Published var isOrbPressed: Bool = false
    @Published var isPeekHovered: Bool = false
    @Published var hoveredRowId: String? = nil
    @Published var selectedKeyboardIndex: Int = 0
    @Published var settingsTab: Int = 0 // 0: 监控软件, 1: 外观与快捷键, 2: 提醒与屏蔽
    @Published var dismissedSetupHint: Bool = false
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    @AppStorage("warningMinutes") var warningMinutes: Int = 5
    @AppStorage("overdueMinutes") var overdueMinutes: Int = 15
    @AppStorage("repeatOverdueEveryMinutes") var repeatOverdueEveryMinutes: Int = 10
    @AppStorage("sortOldestFirst") var sortOldestFirst: Bool = true
    @AppStorage("appearanceMode") var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage("orbScale") var orbScale: Double = 1.05
    @AppStorage("idleOpacity") var idleOpacity: Double = 0.92
    @AppStorage("windowLevelMode") var windowLevelModeRaw: String = WindowLevelMode.alwaysOnTop.rawValue
    @AppStorage("lockOrbPosition") var lockOrbPosition: Bool = false
    @AppStorage("enableGlobalHotkey") var enableGlobalHotkey: Bool = true

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set {
            appearanceModeRaw = newValue.rawValue
            objectWillChange.send()
            onLayoutNeedsUpdate?(false)
        }
    }

    var windowLevelMode: WindowLevelMode {
        get { WindowLevelMode(rawValue: windowLevelModeRaw) ?? .alwaysOnTop }
        set {
            windowLevelModeRaw = newValue.rawValue
            objectWillChange.send()
            onWindowConfigChanged?()
        }
    }

    var isPeeksPaused: Bool {
        guard let until = pausePeeksUntil else { return false }
        return now < until
    }

    var enabledApps: [MonitoredApp] {
        monitoredApps.filter(\.isEnabled)
    }

    var surfaceMode: SurfaceMode {
        if isExpanded { return .expanded }
        if let activePeek { return .peek(activePeek) }
        return .compact
    }

    var onLayoutNeedsUpdate: ((Bool) -> Void)?
    var onWindowConfigChanged: (() -> Void)?
    var onHotkeySettingChanged: ((Bool) -> Void)?
    var onMonitoredAppsChanged: (([MonitoredApp]) -> Void)?
    var onSnapCornerRequested: ((ScreenCorner) -> Void)?
    var onJumpRequested: ((MessageItem, MonitoredApp) -> JumpOutcome)?
    var onOpenAppRequested: ((MonitoredApp) -> Void)?

    private var agingTimer: Timer?
    private var peekDismissTask: Task<Void, Never>?
    private var undoDismissTask: Task<Void, Never>?
    private var noticeDismissTask: Task<Void, Never>?

    private var seenNotificationKeys: Set<String> = []
    private var handledRevisions: [String: String] = [:]
    private var previousDockBadges: [String: DockBadgeReading] = [:]
    private var missingSidebarScanCounts: [String: Int] = [:]

    private let stateFileURL: URL
    private let appsFileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stateFileURL = dir.appendingPathComponent("queue_state_v5.json")
        self.appsFileURL = dir.appendingPathComponent("monitored_apps_v1.json")

        loadMonitoredApps()
        loadPersistedState()
        startAgingTicker()
    }

    // MARK: - Monitored Apps Management (Zero Rebuild Needed!)

    func app(for id: String) -> MonitoredApp {
        if let found = monitoredApps.first(where: { $0.id == id }) {
            return found
        }
        return MonitoredApp(
            id: id,
            displayName: id,
            mainBundleIds: [id],
            helperBundleIds: [],
            dockTileNames: [id],
            isEnabled: true,
            supportsTenantRail: false,
            isBuiltIn: false
        )
    }

    func toggleAppEnabled(_ appId: String) {
        guard let idx = monitoredApps.firstIndex(where: { $0.id == appId }) else { return }
        monitoredApps[idx].isEnabled.toggle()
        let isNowEnabled = monitoredApps[idx].isEnabled
        if !isNowEnabled {
            items.removeAll { $0.appId == appId }
            if selectedFilterAppId == appId { selectedFilterAppId = nil }
        }
        saveMonitoredApps()
        savePersistedState()
        onMonitoredAppsChanged?(monitoredApps)
        onLayoutNeedsUpdate?(true)
    }

    func addOrEnableApp(_ candidate: MonitoredApp) {
        if let existingIdx = monitoredApps.firstIndex(where: {
            $0.id == candidate.id || !Set($0.mainBundleIds).isDisjoint(with: candidate.mainBundleIds)
        }) {
            monitoredApps[existingIdx].isEnabled = true
            showNotice("已启用监控：\(monitoredApps[existingIdx].displayName)")
        } else {
            monitoredApps.append(candidate)
            showNotice("已添加监控软件：\(candidate.displayName)")
        }
        saveMonitoredApps()
        onMonitoredAppsChanged?(monitoredApps)
        onLayoutNeedsUpdate?(true)
    }

    func removeCustomApp(_ appId: String) {
        guard let idx = monitoredApps.firstIndex(where: { $0.id == appId }),
              !monitoredApps[idx].isBuiltIn else { return }
        let removedName = monitoredApps[idx].displayName
        monitoredApps.remove(at: idx)
        items.removeAll { $0.appId == appId }
        if selectedFilterAppId == appId { selectedFilterAppId = nil }
        saveMonitoredApps()
        savePersistedState()
        onMonitoredAppsChanged?(monitoredApps)
        showNotice("已移除：\(removedName)")
        onLayoutNeedsUpdate?(true)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            showNotice("开机自启需从 /Applications 目录运行设置")
        }
    }

    // MARK: - Focus / Meeting Pause & Conversation Mute Rules

    func pausePeeks(minutes: Int) {
        if minutes <= 0 {
            pausePeeksUntil = nil
            showNotice("已恢复新消息轻提示弹窗")
        } else {
            pausePeeksUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
            dismissPeek(notifyLayout: false)
            showNotice("已开启 \(minutes) 分钟免弹窗专注模式（后台仍自动收录）")
        }
        onLayoutNeedsUpdate?(true)
    }

    func isMuted(appId: String, sender: String) -> Bool {
        let clean = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        return mutedRules.contains { $0.appId == appId && $0.sender == clean }
    }

    func muteConversation(_ item: MessageItem) {
        let appObj = app(for: item.appId)
        let rule = MutedConversationRule(
            appId: item.appId,
            appName: appObj.displayName,
            sender: item.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !mutedRules.contains(rule) {
            mutedRules.append(rule)
        }
        items.removeAll { $0.appId == item.appId && $0.sender == item.sender }
        savePersistedState()
        presentUndo(UndoSnapshot(item: item, mutedRule: rule, label: "已屏蔽「\(item.sender)」"))
        onLayoutNeedsUpdate?(true)
    }

    func removeMutedRule(_ rule: MutedConversationRule) {
        mutedRules.removeAll { $0 == rule }
        savePersistedState()
        onMonitoredAppsChanged?(monitoredApps) // Trigger fresh scan
        onLayoutNeedsUpdate?(true)
    }

    // MARK: - Aging Ticker

    private func startAgingTicker() {
        agingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func tick() {
        let current = Date()
        now = current

        if let pUntil = pausePeeksUntil, current >= pUntil {
            pausePeeksUntil = nil
        }

        var wokeUpSnooze = false
        for idx in items.indices {
            if let until = items[idx].snoozedUntil, current >= until {
                items[idx].snoozedUntil = nil
                wokeUpSnooze = true
            }
        }

        checkAndTriggerOverduePeek(at: current)
        if wokeUpSnooze {
            savePersistedState()
            onLayoutNeedsUpdate?(true)
        }
    }

    // MARK: - Computed Queue Views

    var activeItems: [MessageItem] {
        let enabledIds = Set(enabledApps.map(\.id))
        return items.filter {
            enabledIds.contains($0.appId)
                && !$0.isSnoozed(at: now)
                && !isMuted(appId: $0.appId, sender: $0.sender)
        }
    }

    var snoozedItems: [MessageItem] {
        let enabledIds = Set(enabledApps.map(\.id))
        return items.filter { enabledIds.contains($0.appId) && $0.isSnoozed(at: now) }
            .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
    }

    var displayedQueueItems: [MessageItem] {
        let base = showSnoozedSheet ? snoozedItems : activeItems
        let filteredList: [MessageItem]
        if let filterId = selectedFilterAppId {
            filteredList = base.filter { $0.appId == filterId }
        } else {
            filteredList = base
        }

        return filteredList.sorted { a, b in
            if sortOldestFirst {
                if a.firstObservedAt != b.firstObservedAt {
                    return a.firstObservedAt < b.firstObservedAt
                }
                return a.id < b.id
            } else {
                if a.latestActivityAt != b.latestActivityAt {
                    return a.latestActivityAt > b.latestActivityAt
                }
                return a.id < b.id
            }
        }
    }

    var pendingItemCount: Int {
        activeItems.count
    }

    var hasUnresolvedAggregatePresence: Bool {
        pendingItemCount == 0 && dockBadges.values.contains(where: { $0.hasUnread })
    }

    var oldestAgingLevel: AgingLevel {
        activeItems
            .map { $0.agingLevel(at: now, warningMinutes: warningMinutes, overdueMinutes: overdueMinutes) }
            .max() ?? .fresh
    }

    func pendingCountForApp(_ appId: String) -> Int {
        activeItems.filter { $0.appId == appId }.count
    }

    // MARK: - Keyboard Navigation Inside Expanded Queue

    func moveKeyboardSelection(delta: Int) {
        let list = displayedQueueItems
        guard !list.isEmpty else { return }
        selectedKeyboardIndex = min(max(selectedKeyboardIndex + delta, 0), list.count - 1)
    }

    func triggerKeyboardOpen() {
        let list = displayedQueueItems
        guard selectedKeyboardIndex >= 0, selectedKeyboardIndex < list.count else { return }
        handleRowTap(list[selectedKeyboardIndex])
    }

    func triggerKeyboardComplete() {
        let list = displayedQueueItems
        guard selectedKeyboardIndex >= 0, selectedKeyboardIndex < list.count else { return }
        completeItem(list[selectedKeyboardIndex])
        let newCount = displayedQueueItems.count
        if selectedKeyboardIndex >= newCount {
            selectedKeyboardIndex = max(0, newCount - 1)
        }
    }

    func triggerKeyboardSnooze() {
        let list = displayedQueueItems
        guard selectedKeyboardIndex >= 0, selectedKeyboardIndex < list.count else { return }
        snooze(list[selectedKeyboardIndex], minutes: 15)
    }

    // MARK: - 1. Ingest System / Notifier Deliveries

    func ingestNotifications(_ batch: [UserNotedWatcher.RawNotification], isStartupBackfill: Bool) {
        var addedNewest: MessageItem? = nil
        var mutated = false

        for raw in batch {
            let recKey = "rec-\(raw.recId)"
            guard !seenNotificationKeys.contains(recKey) else { continue }
            seenNotificationKeys.insert(recKey)

            let targetApp = app(for: raw.appId)
            guard targetApp.isEnabled else { continue }

            if isStartupBackfill, dockBadges[targetApp.id] == .clear {
                continue
            }

            let sender = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedSender = sender.isEmpty ? targetApp.displayName : sender
            guard !isMuted(appId: targetApp.id, sender: resolvedSender) else { continue }

            let sub = raw.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = raw.body.trimmingCharacters(in: .whitespacesAndNewlines)

            let convKey = canonicalConversationId(appId: targetApp.id, tenant: nil, sender: resolvedSender)
            let revision = "\(recKey)|\(body)"
            if handledRevisions[convKey] == revision { continue }

            items.removeAll { $0.appId == targetApp.id && $0.sourceKind == .dockHint }

            if let existingIdx = items.firstIndex(where: { $0.id == convKey }) {
                items[existingIdx].body = body.isEmpty ? items[existingIdx].body : body
                if !sub.isEmpty { items[existingIdx].subtitle = sub }
                if raw.deliveredAt > items[existingIdx].latestActivityAt {
                    items[existingIdx].latestActivityAt = raw.deliveredAt
                }
                items[existingIdx].contentRevision = revision
                items[existingIdx].snoozedUntil = nil
                addedNewest = items[existingIdx]
                mutated = true
            } else {
                let entry = MessageItem(
                    id: convKey,
                    appId: targetApp.id,
                    bundleId: targetApp.primaryBundleId,
                    tenantName: nil,
                    sender: resolvedSender,
                    subtitle: sub,
                    body: body.isEmpty ? "发来一条新消息" : body,
                    unreadBadgeText: nil,
                    firstObservedAt: raw.deliveredAt,
                    latestActivityAt: raw.deliveredAt,
                    isTimestampExact: true,
                    snoozedUntil: nil,
                    sourceKind: .notification,
                    lastNotifiedOverdueAt: nil,
                    contentRevision: revision
                )
                items.append(entry)
                addedNewest = entry
                mutated = true
            }
        }

        guard mutated else { return }
        now = Date()
        savePersistedState()

        if !isStartupBackfill, let newest = addedNewest, !isExpanded, !isPeeksPaused {
            presentPeek(.incoming(newest), durationSeconds: 4.4)
        } else {
            onLayoutNeedsUpdate?(true)
        }
    }

    // MARK: - 2. Reconcile Live AX World

    func reconcileAXObservation(_ obs: AXWorldObservation) {
        let prevTrust = hasAccessibilityPermission
        hasAccessibilityPermission = obs.trusted
        var mutated = (prevTrust != obs.trusted)
        let current = Date()
        now = current

        guard obs.trusted else {
            if mutated { onLayoutNeedsUpdate?(true) }
            return
        }

        let prevDock = previousDockBadges
        dockBadges = obs.dockBadges
        previousDockBadges = obs.dockBadges

        // A. Live System NotificationCenter & Helper Banners
        for banner in obs.liveSystemBanners {
            let targetApp = app(for: banner.appId)
            guard targetApp.isEnabled, !isMuted(appId: banner.appId, sender: banner.title) else { continue }

            let convId = canonicalConversationId(appId: banner.appId, tenant: banner.tenantName, sender: banner.title)
            let rev = "banner|\(banner.appId)|\(banner.title)|\(banner.preview)"
            guard handledRevisions[convId] != rev else { continue }

            items.removeAll { $0.appId == banner.appId && $0.sourceKind == .dockHint }

            if let idx = items.firstIndex(where: { $0.id == convId }) {
                if items[idx].contentRevision != rev {
                    items[idx].body = banner.preview
                    items[idx].latestActivityAt = current
                    items[idx].contentRevision = rev
                    items[idx].snoozedUntil = nil
                    mutated = true
                    if !isExpanded && !isPeeksPaused { presentPeek(.incoming(items[idx]), durationSeconds: 4.4) }
                }
            } else {
                let item = MessageItem(
                    id: convId,
                    appId: banner.appId,
                    bundleId: targetApp.primaryBundleId,
                    tenantName: banner.tenantName,
                    sender: banner.title,
                    subtitle: banner.tenantName ?? "",
                    body: banner.preview,
                    unreadBadgeText: banner.badgeText,
                    firstObservedAt: current,
                    latestActivityAt: current,
                    isTimestampExact: true,
                    snoozedUntil: nil,
                    sourceKind: .notification,
                    lastNotifiedOverdueAt: nil,
                    contentRevision: rev
                )
                items.append(item)
                mutated = true
                if !isExpanded && !isPeeksPaused { presentPeek(.incoming(item), durationSeconds: 4.4) }
            }
        }

        // B. Visible Sidebar Unread Conversations
        var observedConvIdsByApp: [String: Set<String>] = [:]
        var newestSidebarArrival: MessageItem? = nil

        for snap in obs.conversations {
            let targetApp = app(for: snap.appId)
            guard targetApp.isEnabled, !isMuted(appId: snap.appId, sender: snap.title) else { continue }

            let convId = canonicalConversationId(appId: snap.appId, tenant: snap.tenantName, sender: snap.title)
            observedConvIdsByApp[snap.appId, default: []].insert(convId)

            let rev = "ax|\(snap.badgeText)|\(snap.preview)"
            if handledRevisions[convId] == rev { continue }

            items.removeAll { $0.appId == snap.appId && $0.sourceKind == .dockHint }

            if let idx = items.firstIndex(where: { $0.id == convId }) {
                if items[idx].contentRevision != rev {
                    let prevBadge = items[idx].unreadBadgeText
                    items[idx].body = snap.preview
                    items[idx].unreadBadgeText = snap.badgeText
                    if let t = snap.tenantName, !t.isEmpty {
                        items[idx].tenantName = t
                        items[idx].subtitle = t
                    }
                    items[idx].contentRevision = rev
                    if prevBadge != snap.badgeText {
                        items[idx].latestActivityAt = current
                        items[idx].snoozedUntil = nil
                        newestSidebarArrival = items[idx]
                    }
                    mutated = true
                }
            } else {
                let newItem = MessageItem(
                    id: convId,
                    appId: snap.appId,
                    bundleId: targetApp.primaryBundleId,
                    tenantName: snap.tenantName,
                    sender: snap.title,
                    subtitle: snap.tenantName ?? "",
                    body: snap.preview,
                    unreadBadgeText: snap.badgeText,
                    firstObservedAt: current,
                    latestActivityAt: current,
                    isTimestampExact: false,
                    snoozedUntil: nil,
                    sourceKind: .sidebarSnapshot,
                    lastNotifiedOverdueAt: nil,
                    contentRevision: rev
                )
                items.append(newItem)
                newestSidebarArrival = newItem
                mutated = true
            }
        }

        for appId in obs.readableSidebarAppIds {
            let visibleIds = observedConvIdsByApp[appId] ?? []
            var toRetire: Set<String> = []
            for item in items where item.appId == appId && item.sourceKind == .sidebarSnapshot && !item.isSnoozed(at: current) {
                if visibleIds.contains(item.id) {
                    missingSidebarScanCounts[item.id] = 0
                } else {
                    let c = (missingSidebarScanCounts[item.id] ?? 0) + 1
                    missingSidebarScanCounts[item.id] = c
                    if c >= 2 {
                        toRetire.insert(item.id)
                        missingSidebarScanCounts.removeValue(forKey: item.id)
                    }
                }
            }
            if !toRetire.isEmpty {
                items.removeAll { toRetire.contains($0.id) }
                mutated = true
            }
        }

        // C. Multi-Tenant Rail Hints (Feishu, DingTalk, Slack)
        var activeTenantHintIdsByApp: [String: Set<String>] = [:]
        for hint in obs.tenantHints where !hint.isSelected {
            let targetApp = app(for: hint.appId)
            guard targetApp.isEnabled, !isMuted(appId: hint.appId, sender: hint.tenantName) else { continue }

            let hintId = "tenant|\(hint.appId)|\(hint.tenantName)"
            activeTenantHintIdsByApp[hint.appId, default: []].insert(hintId)
            let rev = "tenant|\(hint.badgeText)"
            if handledRevisions[hintId] == rev { continue }

            items.removeAll { $0.appId == hint.appId && $0.sourceKind == .dockHint }

            if let idx = items.firstIndex(where: { $0.id == hintId }) {
                if items[idx].unreadBadgeText != hint.badgeText {
                    items[idx].unreadBadgeText = hint.badgeText
                    items[idx].body = "该工作区有 \(hint.badgeText) 未读消息，点击直接切换查看"
                    items[idx].contentRevision = rev
                    items[idx].latestActivityAt = current
                    mutated = true
                }
            } else {
                let item = MessageItem(
                    id: hintId,
                    appId: hint.appId,
                    bundleId: targetApp.primaryBundleId,
                    tenantName: hint.tenantName,
                    sender: hint.tenantName,
                    subtitle: "\(targetApp.displayName)其他企业",
                    body: "该工作区有 \(hint.badgeText) 未读消息，点击直接切换查看",
                    unreadBadgeText: hint.badgeText,
                    firstObservedAt: current,
                    latestActivityAt: current,
                    isTimestampExact: false,
                    snoozedUntil: nil,
                    sourceKind: .tenantHint,
                    lastNotifiedOverdueAt: nil,
                    contentRevision: rev
                )
                items.append(item)
                newestSidebarArrival = newestSidebarArrival ?? item
                mutated = true
            }
        }

        for appId in obs.readableSidebarAppIds {
            let keepIds = activeTenantHintIdsByApp[appId] ?? []
            let before = items.count
            items.removeAll { $0.appId == appId && $0.sourceKind == .tenantHint && !keepIds.contains($0.id) }
            if items.count != before { mutated = true }
        }

        // D. Honest Dock Badge Clear & Fallback Coverage
        for monitored in enabledApps {
            let appId = monitored.id
            let reading = obs.dockBadges[appId] ?? .unavailable
            let prevReading = prevDock[appId] ?? .unavailable

            switch reading {
            case .unavailable:
                break

            case .clear:
                let before = items.count
                items.removeAll { $0.appId == appId && $0.sourceKind == .dockHint }
                if prevReading.hasUnread {
                    items.removeAll {
                        $0.appId == appId
                            && $0.sourceKind == .notification
                            && !$0.isSnoozed(at: current)
                    }
                }
                if items.count != before { mutated = true }

            case .dot, .count, .atLeast:
                let hasSpecificItems = items.contains { $0.appId == appId && $0.sourceKind != .dockHint }
                if hasSpecificItems {
                    let before = items.count
                    items.removeAll { $0.appId == appId && $0.sourceKind == .dockHint }
                    if items.count != before { mutated = true }
                } else {
                    let dockId = "dock-hint-\(appId)"
                    let rev = "dock|\(reading.displayText)"
                    if handledRevisions[dockId] == rev { continue }

                    let desc = monitored.supportsTenantRail
                        ? "检测到角标（\(reading.displayText)），展开\(monitored.displayName)窗口可读取具体会话"
                        : "检测到未读角标（\(reading.displayText)），点击打开\(monitored.displayName)"

                    if let idx = items.firstIndex(where: { $0.id == dockId }) {
                        if items[idx].unreadBadgeText != reading.displayText {
                            items[idx].unreadBadgeText = reading.displayText
                            items[idx].body = desc
                            items[idx].contentRevision = rev
                            mutated = true
                        }
                    } else {
                        let hint = MessageItem(
                            id: dockId,
                            appId: appId,
                            bundleId: monitored.primaryBundleId,
                            tenantName: nil,
                            sender: "\(monitored.displayName) 有未读消息",
                            subtitle: "角标提醒",
                            body: desc,
                            unreadBadgeText: reading.displayText,
                            firstObservedAt: current,
                            latestActivityAt: current,
                            isTimestampExact: false,
                            snoozedUntil: nil,
                            sourceKind: .dockHint,
                            lastNotifiedOverdueAt: nil,
                            contentRevision: rev
                        )
                        items.append(hint)
                        mutated = true
                    }
                }
            }
        }

        if mutated {
            savePersistedState()
            if let arrival = newestSidebarArrival, !isExpanded, activePeek == nil, !isPeeksPaused {
                presentPeek(.incoming(arrival), durationSeconds: 4.2)
            } else {
                onLayoutNeedsUpdate?(true)
            }
        }
    }

    private func canonicalConversationId(appId: String, tenant: String?, sender: String) -> String {
        let t = (tenant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let s = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        return "conv|\(appId)|\(t)|\(s)"
    }

    // MARK: - 3. Coalesced Overdue Escalation

    private func checkAndTriggerOverduePeek(at current: Date) {
        guard !isPeeksPaused else { return }

        let allOverdue = activeItems
            .filter { $0.agingLevel(at: current, warningMinutes: warningMinutes, overdueMinutes: overdueMinutes) == .overdue }
            .sorted { $0.firstObservedAt < $1.firstObservedAt }

        guard let oldest = allOverdue.first else { return }

        let repeatSec = TimeInterval(max(3, repeatOverdueEveryMinutes) * 60)
        let dueItems = allOverdue.filter { item in
            guard let last = item.lastNotifiedOverdueAt else { return true }
            return current.timeIntervalSince(last) >= repeatSec
        }
        guard !dueItems.isEmpty else { return }

        if isExpanded {
            if let filterId = selectedFilterAppId, filterId != oldest.appId {
                let oldestAppName = app(for: oldest.appId).displayName
                showNotice("⏰ \(oldestAppName)「\(oldest.sender)」已等待 \(oldest.waitedMinutes(at: current)) 分钟")
            }
        } else {
            presentPeek(
                .overdueDigest(
                    count: allOverdue.count,
                    oldestMinutes: oldest.waitedMinutes(at: current),
                    oldestItem: oldest
                ),
                durationSeconds: 5.5
            )
        }

        for idx in items.indices {
            if items[idx].agingLevel(at: current, warningMinutes: warningMinutes, overdueMinutes: overdueMinutes) == .overdue {
                items[idx].lastNotifiedOverdueAt = current
            }
        }
        savePersistedState()
    }

    // MARK: - 4. User Actions

    func handleRowTap(_ item: MessageItem) {
        let appObj = app(for: item.appId)
        if item.sourceKind == .demo {
            let outcome = onJumpRequested?(item, appObj) ?? .appActivatedNeedsConfirm
            completeItem(item, undoLabel: outcome.feedbackText(appName: appObj.displayName))
            return
        }

        let outcome = onJumpRequested?(item, appObj) ?? .appActivatedNeedsConfirm
        if outcome.resolvedConversationDirectly {
            completeItem(item, undoLabel: "已定位「\(item.sender)」")
        } else {
            showNotice(outcome.feedbackText(appName: appObj.displayName))
            if case .incoming(let peekItem) = activePeek, peekItem.id == item.id {
                dismissPeek()
            }
        }
    }

    func completeItem(_ item: MessageItem, undoLabel: String? = nil) {
        items.removeAll { $0.id == item.id }
        handledRevisions[item.id] = item.contentRevision
        savePersistedState()

        if case .incoming(let peekItem) = activePeek, peekItem.id == item.id {
            dismissPeek(notifyLayout: false)
        }
        presentUndo(UndoSnapshot(item: item, mutedRule: nil, label: undoLabel ?? "已完成「\(item.sender)」"))
        onLayoutNeedsUpdate?(true)
    }

    func snooze(_ item: MessageItem, minutes: Int = 15) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        items[idx].lastNotifiedOverdueAt = nil
        savePersistedState()

        if case .incoming(let peekItem) = activePeek, peekItem.id == item.id {
            dismissPeek(notifyLayout: false)
        }
        showNotice("已稍后提醒（\(minutes)m）：\(item.sender)")
        onLayoutNeedsUpdate?(true)
    }

    func undoLastAction() {
        guard let snap = undoBanner else { return }
        undoDismissTask?.cancel()
        undoBanner = nil
        if let rule = snap.mutedRule {
            mutedRules.removeAll { $0 == rule }
        }
        handledRevisions.removeValue(forKey: snap.item.id)
        if !items.contains(where: { $0.id == snap.item.id }) {
            items.append(snap.item)
        }
        savePersistedState()
        onLayoutNeedsUpdate?(true)
    }

    func clearVisibleCompleted() {
        let targets = displayedQueueItems
        for t in targets {
            handledRevisions[t.id] = t.contentRevision
        }
        let ids = Set(targets.map(\.id))
        items.removeAll { ids.contains($0.id) }
        savePersistedState()
        onLayoutNeedsUpdate?(true)
    }

    func toggleExpanded() {
        isExpanded.toggle()
        if isExpanded {
            selectedKeyboardIndex = 0
            showSnoozedSheet = false
            dismissPeek(notifyLayout: false)
        } else {
            showSettings = false
        }
        onLayoutNeedsUpdate?(true)
    }

    func collapsePanel() {
        guard isExpanded else { return }
        isExpanded = false
        showSettings = false
        onLayoutNeedsUpdate?(true)
    }

    // MARK: - Peek & Transient Feedback Timers

    func presentPeek(_ payload: PeekPayload, durationSeconds: Double) {
        peekDismissTask?.cancel()
        activePeek = payload
        onLayoutNeedsUpdate?(true)
        schedulePeekAutoCollapse(durationSeconds: durationSeconds)
    }

    func setPeekHovering(_ hovering: Bool) {
        isPeekHovered = hovering
        if hovering {
            peekDismissTask?.cancel()
        } else if activePeek != nil {
            schedulePeekAutoCollapse(durationSeconds: 2.2)
        }
    }

    private func schedulePeekAutoCollapse(durationSeconds: Double) {
        peekDismissTask?.cancel()
        peekDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isPeekHovered else { return }
            self.activePeek = nil
            self.onLayoutNeedsUpdate?(true)
        }
    }

    func dismissPeek(notifyLayout: Bool = true) {
        peekDismissTask?.cancel()
        activePeek = nil
        if notifyLayout {
            onLayoutNeedsUpdate?(true)
        }
    }

    private func presentUndo(_ snapshot: UndoSnapshot) {
        undoDismissTask?.cancel()
        undoBanner = snapshot
        undoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.undoBanner = nil
            self?.onLayoutNeedsUpdate?(true)
        }
    }

    func showNotice(_ text: String) {
        noticeDismissTask?.cancel()
        transientNotice = text
        onLayoutNeedsUpdate?(false)
        noticeDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transientNotice = nil
            self?.onLayoutNeedsUpdate?(false)
        }
    }

    // MARK: - Persistence

    private func loadMonitoredApps() {
        guard let data = try? Data(contentsOf: appsFileURL),
              let saved = try? JSONDecoder().decode([MonitoredApp].self, from: data),
              !saved.isEmpty else {
            monitoredApps = MonitoredApp.defaultApps
            return
        }
        monitoredApps = saved
    }

    private func saveMonitoredApps() {
        if let data = try? JSONEncoder().encode(monitoredApps) {
            try? data.write(to: appsFileURL, options: .atomic)
        }
    }

    private func loadPersistedState() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let decoded = try? JSONDecoder().decode(PersistedQueueState.self, from: data) else {
            return
        }
        self.items = decoded.items.filter { $0.sourceKind != .demo }
        self.handledRevisions = decoded.handledRevisions
        self.seenNotificationKeys = Set(decoded.seenNotificationKeys.suffix(400))
        self.mutedRules = decoded.mutedRules
    }

    private func savePersistedState() {
        if handledRevisions.count > 300 {
            let keysToKeep = Array(handledRevisions.keys.prefix(200))
            var trimmed: [String: String] = [:]
            for k in keysToKeep { trimmed[k] = handledRevisions[k] }
            handledRevisions = trimmed
        }
        let nonDemoItems = items.filter { $0.sourceKind != .demo }
        let state = PersistedQueueState(
            items: nonDemoItems,
            handledRevisions: handledRevisions,
            seenNotificationKeys: Array(seenNotificationKeys.suffix(400)),
            mutedRules: mutedRules
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFileURL, options: .atomic)
        }
    }

    // MARK: - Demo Fixtures

    func injectDemoSample() {
        let nowDate = Date()
        items.removeAll { $0.sourceKind == .demo }

        let demoA = MessageItem(
            id: "demo-feishu-a",
            appId: "feishu",
            bundleId: "com.bytedance.macos.feishu",
            tenantName: "主业A公司",
            sender: "张总",
            subtitle: "主业A公司",
            body: "@你 下午客户演示环境好了吗？看到回一下",
            unreadBadgeText: "2",
            firstObservedAt: nowDate.addingTimeInterval(-19 * 60),
            latestActivityAt: nowDate.addingTimeInterval(-19 * 60),
            isTimestampExact: true,
            snoozedUntil: nil,
            sourceKind: .demo,
            lastNotifiedOverdueAt: nowDate,
            contentRevision: "demo-1"
        )
        let demoB = MessageItem(
            id: "demo-wechat",
            appId: "wechat",
            bundleId: "com.tencent.xinWeChat",
            tenantName: nil,
            sender: "王工（合作方）",
            subtitle: "",
            body: "合同盖章扫描件发你了，麻烦确认下收件信息",
            unreadBadgeText: "1",
            firstObservedAt: nowDate.addingTimeInterval(-8 * 60),
            latestActivityAt: nowDate.addingTimeInterval(-8 * 60),
            isTimestampExact: true,
            snoozedUntil: nil,
            sourceKind: .demo,
            lastNotifiedOverdueAt: nil,
            contentRevision: "demo-2"
        )
        let demoQQ = MessageItem(
            id: "demo-qq",
            appId: "qq",
            bundleId: "com.tencent.qq",
            tenantName: nil,
            sender: "运维监控群",
            subtitle: "",
            body: "阿哲：测试机包已经打好了，随时可以拉取验证",
            unreadBadgeText: "3",
            firstObservedAt: nowDate.addingTimeInterval(-25),
            latestActivityAt: nowDate.addingTimeInterval(-25),
            isTimestampExact: true,
            snoozedUntil: nil,
            sourceKind: .demo,
            lastNotifiedOverdueAt: nil,
            contentRevision: "demo-4"
        )

        items.append(contentsOf: [demoA, demoB, demoQQ])
        now = nowDate
        if !isExpanded {
            presentPeek(.incoming(demoQQ), durationSeconds: 4.5)
        } else {
            onLayoutNeedsUpdate?(true)
        }
    }
}

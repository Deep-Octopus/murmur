import Foundation
import ServiceManagement
import SwiftUI

struct UndoSnapshot {
    let items: [MessageItem]
    let mutedRule: MutedConversationRule?
    let label: String
}

private struct PersistedQueueState: Codable {
    var items: [MessageItem]
    var handledRevisions: [String: String]
    var handledRevisionOrder: [String]?
    var seenNotificationKeys: [String]
    var mutedRules: [MutedConversationRule]
}

@MainActor
final class MessageStore: ObservableObject {
    @Published var monitoredApps: [MonitoredApp] = MonitoredApp.defaultApps
    @Published var items: [MessageItem] = []
    @Published var suppressedMutedItems: [MessageItem] = []
    @Published var mutedRules: [MutedConversationRule] = []

    @Published var isExpanded: Bool = false
    @Published var isPinnedExpanded: Bool = false
    @Published var isModalPickerOpen: Bool = false
    @Published var showSettings: Bool = false
    @Published var showSnoozedSheet: Bool = false
    @Published var showMutedDrawer: Bool = false
    @Published var selectedFilterAppId: String? = nil
    @Published var expandedBodyItemId: String? = nil
    @Published var activePeek: PeekPayload? = nil
    @Published var undoBanner: UndoSnapshot? = nil
    @Published var transientNotice: String? = nil
    @Published var pausePeeksUntil: Date? = nil
    @Published var hotKeyConflictError: Bool = false

    @Published var now: Date = Date()
    @Published var dockBadges: [String: DockBadgeReading] = [:]
    @Published var hasAccessibilityPermission: Bool = true
    @Published var notificationReaderState: NotificationReaderState = .checking

    // UI & Keyboard interaction states (kept on ObservableObject to avoid SwiftUIMacros dependency)
    @Published var isOrbHovering: Bool = false
    @Published var isOrbPressed: Bool = false
    @Published var isPeekHovered: Bool = false
    @Published var hoveredRowId: String? = nil
    @Published var selectedKeyboardIndex: Int = 0
    @Published var settingsTab: Int = 0 // 0: 监控软件, 1: 外观与热键, 2: 降噪与提醒
    @Published var dismissedSetupHint: Bool = false
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    @AppStorage("warningMinutes") var warningMinutes: Int = 5
    @AppStorage("overdueMinutes") var overdueMinutes: Int = 15
    @AppStorage("repeatOverdueEveryMinutes") var repeatOverdueEveryMinutes: Int = 10
    @AppStorage("sortOldestFirst") var sortOldestFirst: Bool = true
    @AppStorage("autoFilterMutedChats") var autoFilterMutedChats: Bool = true
    @AppStorage("hideOrbWhenIdle") var hideOrbWhenIdle: Bool = false
    @AppStorage("appearanceMode") var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage("orbScale") var orbScale: Double = 1.05
    @AppStorage("idleOpacity") var idleOpacity: Double = 0.92
    @AppStorage("windowLevelMode") var windowLevelModeRaw: String = WindowLevelMode.alwaysOnTop.rawValue
    @AppStorage("lockOrbPosition") var lockOrbPosition: Bool = false
    @AppStorage("enableGlobalHotkey") var enableGlobalHotkey: Bool = true
    @AppStorage("hotKeyPreset") var hotKeyPresetRaw: String = HotKeyPreset.optionM.rawValue

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

    var hotKeyPreset: HotKeyPreset {
        get { HotKeyPreset(rawValue: hotKeyPresetRaw) ?? .optionM }
        set {
            hotKeyPresetRaw = newValue.rawValue
            objectWillChange.send()
            onHotkeySettingChanged?(enableGlobalHotkey)
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

    var shouldHideDesktopOrb: Bool {
        hideOrbWhenIdle
            && surfaceMode == .compact
            && pendingItemCount == 0
            && !hasUnresolvedAggregatePresence
    }

    var onLayoutNeedsUpdate: ((Bool) -> Void)?
    var onWindowConfigChanged: (() -> Void)?
    var onHotkeySettingChanged: ((Bool) -> Void)?
    var onMonitoredAppsChanged: (([MonitoredApp]) -> Void)?
    var onSnapCornerRequested: ((ScreenCorner) -> Void)?
    var onJumpRequested: ((MessageItem, MonitoredApp) -> JumpOutcome)?
    var onOpenAppRequested: ((MonitoredApp) -> Void)?
    var onStatusItemNeedsUpdate: (() -> Void)?

    private var agingTimer: Timer?
    private var peekDismissTask: Task<Void, Never>?
    private var undoDismissTask: Task<Void, Never>?
    private var noticeDismissTask: Task<Void, Never>?

    private var seenNotificationKeys: Set<String> = []
    private var handledRevisions: [String: String] = [:]
    private var handledRevisionOrder: [String] = []
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
            sumsUnreadInDockBadge: true,
            isBuiltIn: false
        )
    }

    func toggleAppEnabled(_ appId: String) {
        guard let idx = monitoredApps.firstIndex(where: { $0.id == appId }) else { return }
        monitoredApps[idx].isEnabled.toggle()
        let isNowEnabled = monitoredApps[idx].isEnabled
        if !isNowEnabled {
            items.removeAll { $0.appId == appId }
            suppressedMutedItems.removeAll { $0.appId == appId }
            if selectedFilterAppId == appId { selectedFilterAppId = nil }
        }
        saveMonitoredApps()
        savePersistedState()
        onMonitoredAppsChanged?(monitoredApps)
        onStatusItemNeedsUpdate?()
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
        onStatusItemNeedsUpdate?()
        onLayoutNeedsUpdate?(true)
    }

    func removeCustomApp(_ appId: String) {
        guard let idx = monitoredApps.firstIndex(where: { $0.id == appId }),
              !monitoredApps[idx].isBuiltIn else { return }
        let removedName = monitoredApps[idx].displayName
        monitoredApps.remove(at: idx)
        items.removeAll { $0.appId == appId }
        suppressedMutedItems.removeAll { $0.appId == appId }
        if selectedFilterAppId == appId { selectedFilterAppId = nil }
        saveMonitoredApps()
        savePersistedState()
        onMonitoredAppsChanged?(monitoredApps)
        onStatusItemNeedsUpdate?()
        showNotice("已移除：\(removedName)")
        onLayoutNeedsUpdate?(true)
    }

    func setAutoFilterMutedChats(_ enabled: Bool) {
        autoFilterMutedChats = enabled
        if !enabled {
            suppressedMutedItems = []
            showMutedDrawer = false
        }
        objectWillChange.send()
        onMonitoredAppsChanged?(monitoredApps)
        onLayoutNeedsUpdate?(true)
    }

    func setHideOrbWhenIdle(_ enabled: Bool) {
        hideOrbWhenIdle = enabled
        objectWillChange.send()
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
        onStatusItemNeedsUpdate?()
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
        let removedActive = items.filter { $0.appId == item.appId && $0.sender == item.sender }
        items.removeAll { $0.appId == item.appId && $0.sender == item.sender }
        suppressedMutedItems.removeAll { $0.appId == item.appId && $0.sender == item.sender }
        savePersistedState()
        presentUndo(
            UndoSnapshot(
                items: removedActive,
                mutedRule: rule,
                label: "已永久屏蔽「\(item.sender)」"
            )
        )
        onStatusItemNeedsUpdate?()
        onLayoutNeedsUpdate?(true)
    }

    func removeMutedRule(_ rule: MutedConversationRule) {
        mutedRules.removeAll { $0 == rule }
        savePersistedState()
        onMonitoredAppsChanged?(monitoredApps)
        onStatusItemNeedsUpdate?()
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

        var statusChanged = false
        if let pUntil = pausePeeksUntil, current >= pUntil {
            pausePeeksUntil = nil
            statusChanged = true
        }

        var wokeUpSnooze = false
        for idx in items.indices {
            if let until = items[idx].snoozedUntil, current >= until {
                items[idx].snoozedUntil = nil
                wokeUpSnooze = true
            }
        }

        checkAndTriggerOverduePeek(at: current)
        if wokeUpSnooze || statusChanged {
            if wokeUpSnooze { savePersistedState() }
            onStatusItemNeedsUpdate?()
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

    var displayedSuppressedMutedItems: [MessageItem] {
        guard autoFilterMutedChats, !showSnoozedSheet else { return [] }
        let enabledIds = Set(enabledApps.map(\.id))
        let base = suppressedMutedItems.filter {
            enabledIds.contains($0.appId) && !isMuted(appId: $0.appId, sender: $0.sender)
        }
        if let filterId = selectedFilterAppId {
            return base.filter { $0.appId == filterId }
        }
        return base
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

    func triggerKeyboardToggleBody() {
        let list = displayedQueueItems
        guard selectedKeyboardIndex >= 0, selectedKeyboardIndex < list.count else { return }
        toggleExpandedBody(for: list[selectedKeyboardIndex].id)
    }

    func toggleExpandedBody(for itemId: String) {
        if expandedBodyItemId == itemId {
            expandedBodyItemId = nil
        } else {
            expandedBodyItemId = itemId
        }
        onLayoutNeedsUpdate?(true)
    }

    // MARK: - FIFO Handled Revisions Tracking

    private func recordHandledRevision(id: String, revision: String) {
        handledRevisions[id] = revision
        handledRevisionOrder.removeAll { $0 == id }
        handledRevisionOrder.append(id)
    }

    private func removeHandledRevision(id: String) {
        handledRevisions.removeValue(forKey: id)
        handledRevisionOrder.removeAll { $0 == id }
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

            // Never backfill old notifications if Dock says 0 unread
            if isStartupBackfill {
                let dock = dockBadges[targetApp.id] ?? .unavailable
                if dock == .clear || dock == .unavailable {
                    continue
                }
            }

            let sender = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedSender = sender.isEmpty ? targetApp.displayName : sender
            guard !isMuted(appId: targetApp.id, sender: resolvedSender) else { continue }

            let sub = raw.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = raw.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let mention = AccessibilityBridge.containsMentionBreakthrough(body)
                || AccessibilityBridge.containsMentionBreakthrough(resolvedSender)
                || AccessibilityBridge.containsMentionBreakthrough(sub)

            let defaultConvKey = canonicalConversationId(appId: targetApp.id, tenant: nil, sender: resolvedSender)
            let revision = "\(recKey)|\(body)"

            // Reuse existing tenant-scoped conversation if already present in queue (prevents split-brain duplicates)
            let existingIdx = items.firstIndex(where: { $0.id == defaultConvKey })
                ?? items.firstIndex(where: {
                    $0.appId == targetApp.id
                        && $0.sender == resolvedSender
                        && $0.sourceKind != .tenantHint
                        && $0.sourceKind != .dockHint
                })

            let checkKey = existingIdx.map { items[$0].id } ?? defaultConvKey
            if handledRevisions[checkKey] == revision || handledRevisions[defaultConvKey] == revision {
                continue
            }

            items.removeAll { $0.appId == targetApp.id && $0.sourceKind == .dockHint }

            if let idx = existingIdx {
                items[idx].body = body.isEmpty ? items[idx].body : body
                if !sub.isEmpty && items[idx].subtitle.isEmpty {
                    items[idx].subtitle = sub
                }
                if mention { items[idx].hasMentionBreakthrough = true }
                if raw.deliveredAt > items[idx].latestActivityAt {
                    items[idx].latestActivityAt = raw.deliveredAt
                }
                items[idx].contentRevision = revision
                items[idx].snoozedUntil = nil
                addedNewest = items[idx]
                mutated = true
            } else {
                let entry = MessageItem(
                    id: defaultConvKey,
                    appId: targetApp.id,
                    bundleId: targetApp.primaryBundleId,
                    tenantName: nil,
                    sender: resolvedSender,
                    subtitle: sub,
                    body: body.isEmpty ? "发来一条新消息" : body,
                    unreadBadgeText: nil,
                    hasMentionBreakthrough: mention,
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
        onStatusItemNeedsUpdate?()

        if !isStartupBackfill, let newest = addedNewest, !isExpanded, !isPeeksPaused {
            presentPeek(.incoming(newest), durationSeconds: 4.4)
        } else {
            onLayoutNeedsUpdate?(true)
        }
    }

    // MARK: - 2. 5-Layer Muted Chat Classifier & Live AX World Reconciliation

    private func classifyAttention(
        for snap: ConversationSnapshot,
        app targetApp: MonitoredApp,
        dock: DockBadgeReading,
        current: Date
    ) -> ConversationAttentionKind {
        // Layer 1: Explicit @我 / @所有人 / urgent mention ALWAYS breaks through into primary queue!
        if snap.hasMentionBreakthrough {
            return .mentionedInMuted
        }

        guard autoFilterMutedChats else {
            return .directOrUnmuted
        }

        // Layer 2: Explicit mute icon/DOM class, noise aggregator folder (折叠的群聊/免打扰/订阅号),
        // leading `[14条]` muted count prefix, or non-numeric dot-only sidebar indicator (`•`)
        if snap.hasExplicitMuteSignal {
            return .mutedNoise
        }

        // Layer 3: macOS Dock Truth Anchor == 0 (`clear`)
        // IM apps exclude muted chats from their Dock AXStatusLabel. When Dock is clear, any lingering
        // sidebar unread count without `@我` (unless a brand-new <4s banner just arrived) is a muted chat!
        if dock == .clear {
            let hasFreshLiveBanner = items.contains { existing in
                existing.appId == snap.appId
                    && existing.sender == snap.title
                    && existing.sourceKind == .notification
                    && current.timeIntervalSince(existing.latestActivityAt) < 4.0
            }
            if !hasFreshLiveBanner {
                return .mutedNoise
            }
        }

        // Layer 4: Mathematical Upper-Bound vs Unmuted Dock Total
        // For apps that sum unmuted messages in Dock (Feishu, WeChat, QQ, DingTalk, WeCom, Telegram, Mail),
        // any single group row with unread count strictly greater than the entire app's Dock badge MUST be muted!
        if targetApp.sumsUnreadInDockBadge, case .count(let dockTotal) = dock {
            if let rowCount = snap.badgeIntValue, rowCount > dockTotal {
                return .mutedNoise
            }
            if snap.badgeText.contains("+") && dockTotal < 99 {
                return .mutedNoise
            }
        }

        return .directOrUnmuted
    }

    func reconcileAXObservation(_ obs: AXWorldObservation) {
        let prevTrust = hasAccessibilityPermission
        hasAccessibilityPermission = obs.trusted
        var mutated = (prevTrust != obs.trusted)
        let current = Date()
        now = current

        guard obs.trusted else {
            if mutated {
                onStatusItemNeedsUpdate?()
                onLayoutNeedsUpdate?(true)
            }
            return
        }

        let prevHadPresence = hasUnresolvedAggregatePresence
        dockBadges = obs.dockBadges

        // A. Live System NotificationCenter & Helper Banners (Muted chats never fire OS banners unless @mentioned!)
        for banner in obs.liveSystemBanners {
            let targetApp = app(for: banner.appId)
            guard targetApp.isEnabled, !isMuted(appId: banner.appId, sender: banner.title) else { continue }
            guard !AccessibilityBridge.isNoiseAggregatorFolder(banner.title) else { continue }

            let defaultConvId = canonicalConversationId(appId: banner.appId, tenant: banner.tenantName, sender: banner.title)
            let rev = "banner|\(banner.appId)|\(banner.title)|\(banner.preview)"

            // Reuse tenant-scoped item if already tracked for the same sender
            let existingIdx = items.firstIndex(where: { $0.id == defaultConvId })
                ?? items.firstIndex(where: {
                    $0.appId == banner.appId
                        && $0.sender == banner.title
                        && $0.sourceKind != .tenantHint
                        && $0.sourceKind != .dockHint
                })

            let checkId = existingIdx.map { items[$0].id } ?? defaultConvId
            guard handledRevisions[checkId] != rev && handledRevisions[defaultConvId] != rev else { continue }

            items.removeAll { $0.appId == banner.appId && $0.sourceKind == .dockHint }

            if let idx = existingIdx {
                if items[idx].contentRevision != rev {
                    items[idx].body = banner.preview
                    if banner.hasMentionBreakthrough { items[idx].hasMentionBreakthrough = true }
                    items[idx].latestActivityAt = current
                    items[idx].contentRevision = rev
                    items[idx].snoozedUntil = nil
                    mutated = true
                    if !isExpanded && !isPeeksPaused { presentPeek(.incoming(items[idx]), durationSeconds: 4.4) }
                }
            } else {
                let item = MessageItem(
                    id: defaultConvId,
                    appId: banner.appId,
                    bundleId: targetApp.primaryBundleId,
                    tenantName: banner.tenantName,
                    sender: banner.title,
                    subtitle: banner.tenantName ?? "",
                    body: banner.preview,
                    unreadBadgeText: banner.badgeText,
                    hasMentionBreakthrough: banner.hasMentionBreakthrough,
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

        // B. Visible Sidebar Unread Conversations (With 5-Layer Muted Chat Filtering + Tenant Deduplication)
        var observedActiveConvIdsByApp: [String: Set<String>] = [:]
        var observedActiveSendersByApp: [String: Set<String>] = [:]
        var nextSuppressedMuted: [MessageItem] = []
        var newestSidebarArrival: MessageItem? = nil

        for snap in obs.conversations {
            let targetApp = app(for: snap.appId)
            guard targetApp.isEnabled, !isMuted(appId: snap.appId, sender: snap.title) else { continue }

            let dock = obs.dockBadges[snap.appId] ?? .unavailable
            let attention = classifyAttention(for: snap, app: targetApp, dock: dock, current: current)
            let convId = canonicalConversationId(appId: snap.appId, tenant: snap.tenantName, sender: snap.title)

            if attention == .mutedNoise {
                // Keep out of active queue & NEVER mark handledRevisions so a future @我 immediately promotes!
                let beforeCount = items.count
                items.removeAll {
                    ($0.id == convId || ($0.appId == snap.appId && $0.tenantName == nil && $0.sender == snap.title))
                        && $0.sourceKind == .sidebarSnapshot
                }
                if items.count != beforeCount { mutated = true }

                let prevSuppressed = suppressedMutedItems.first { $0.id == convId }
                let mutedEntry = MessageItem(
                    id: convId,
                    appId: snap.appId,
                    bundleId: targetApp.primaryBundleId,
                    tenantName: snap.tenantName,
                    sender: snap.title,
                    subtitle: snap.tenantName ?? "免打扰",
                    body: snap.preview,
                    unreadBadgeText: snap.badgeText == "有未读" ? nil : snap.badgeText,
                    hasMentionBreakthrough: false,
                    firstObservedAt: prevSuppressed?.firstObservedAt ?? current,
                    latestActivityAt: current,
                    isTimestampExact: false,
                    snoozedUntil: nil,
                    sourceKind: .sidebarSnapshot,
                    lastNotifiedOverdueAt: nil,
                    contentRevision: "muted|\(snap.badgeText)|\(snap.preview)"
                )
                nextSuppressedMuted.append(mutedEntry)
                continue
            }

            let isMention = (attention == .mentionedInMuted) || snap.hasMentionBreakthrough
            observedActiveConvIdsByApp[snap.appId, default: []].insert(convId)
            observedActiveSendersByApp[snap.appId, default: []].insert(snap.title)

            // Merge unscoped notification item into tenant-scoped conversation if needed
            if let tenant = snap.tenantName, !tenant.isEmpty {
                let unscopedId = canonicalConversationId(appId: snap.appId, tenant: nil, sender: snap.title)
                if unscopedId != convId,
                   !items.contains(where: { $0.id == convId }),
                   let uIdx = items.firstIndex(where: { $0.id == unscopedId }) {
                    let old = items[uIdx]
                    let upgraded = MessageItem(
                        id: convId,
                        appId: old.appId,
                        bundleId: old.bundleId,
                        tenantName: tenant,
                        sender: old.sender,
                        subtitle: tenant,
                        body: snap.preview,
                        unreadBadgeText: snap.badgeText,
                        hasMentionBreakthrough: old.hasMentionBreakthrough || isMention,
                        firstObservedAt: old.firstObservedAt,
                        latestActivityAt: old.latestActivityAt,
                        isTimestampExact: old.isTimestampExact,
                        snoozedUntil: old.snoozedUntil,
                        sourceKind: .sidebarSnapshot,
                        lastNotifiedOverdueAt: old.lastNotifiedOverdueAt,
                        contentRevision: "ax|\(snap.badgeText)|\(snap.preview)"
                    )
                    items[uIdx] = upgraded
                    mutated = true
                }
            }

            let rev = "ax|\(snap.badgeText)|\(snap.preview)"
            if handledRevisions[convId] == rev { continue }

            items.removeAll { $0.appId == snap.appId && $0.sourceKind == .dockHint }

            if let idx = items.firstIndex(where: { $0.id == convId }) {
                if items[idx].contentRevision != rev || items[idx].hasMentionBreakthrough != isMention {
                    let prevBadge = items[idx].unreadBadgeText
                    items[idx].body = snap.preview
                    items[idx].unreadBadgeText = snap.badgeText
                    items[idx].hasMentionBreakthrough = isMention
                    items[idx].sourceKind = .sidebarSnapshot
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
                    hasMentionBreakthrough: isMention,
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

        // Retire read conversations ONLY within the currently active tenant's visible sidebar
        for appId in obs.readableSidebarAppIds {
            let visibleIds = observedActiveConvIdsByApp[appId] ?? []
            let visibleSenders = observedActiveSendersByApp[appId] ?? []
            let activeTenant = obs.activeTenantByAppId[appId]
            var toRetire: Set<String> = []

            for item in items where item.appId == appId && !item.isSnoozed(at: current) {
                let inCurrentTenantScope = (activeTenant == nil || item.tenantName == nil || item.tenantName == activeTenant)
                guard inCurrentTenantScope else { continue }

                if item.sourceKind == .sidebarSnapshot {
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
                } else if item.sourceKind == .notification && current.timeIntervalSince(item.latestActivityAt) > 6.5 {
                    if visibleIds.contains(item.id) || visibleSenders.contains(item.sender) {
                        missingSidebarScanCounts[item.id] = 0
                    } else {
                        let c = (missingSidebarScanCounts[item.id] ?? 0) + 1
                        missingSidebarScanCounts[item.id] = c
                        if c >= 3 {
                            toRetire.insert(item.id)
                            missingSidebarScanCounts.removeValue(forKey: item.id)
                        }
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

            let dock = obs.dockBadges[hint.appId] ?? .unavailable
            let hintId = "tenant|\(hint.appId)|\(hint.tenantName)"

            // Dot-only tenant indicator or Dock == clear means that workspace only has muted group chatter!
            if autoFilterMutedChats && (hint.isDotOnly || dock == .clear) {
                let prevSuppressed = suppressedMutedItems.first { $0.id == hintId }
                nextSuppressedMuted.append(
                    MessageItem(
                        id: hintId,
                        appId: hint.appId,
                        bundleId: targetApp.primaryBundleId,
                        tenantName: hint.tenantName,
                        sender: hint.tenantName,
                        subtitle: "\(targetApp.displayName)其他企业 · 免打扰",
                        body: "该工作区仅有免打扰会话动态",
                        unreadBadgeText: nil,
                        hasMentionBreakthrough: false,
                        firstObservedAt: prevSuppressed?.firstObservedAt ?? current,
                        latestActivityAt: current,
                        isTimestampExact: false,
                        snoozedUntil: nil,
                        sourceKind: .tenantHint,
                        lastNotifiedOverdueAt: nil,
                        contentRevision: "muted-tenant|\(hint.badgeText)"
                    )
                )
                continue
            }

            // Don't show a generic tenant hint if we already hold specific unread conversation items for that tenant
            let alreadyHasSpecificForTenant = items.contains {
                $0.appId == hint.appId && $0.tenantName == hint.tenantName && $0.sourceKind != .tenantHint
            }
            if alreadyHasSpecificForTenant {
                continue
            }

            activeTenantHintIdsByApp[hint.appId, default: []].insert(hintId)
            let rev = "tenant|\(hint.badgeText)"
            if handledRevisions[hintId] == rev { continue }

            items.removeAll { $0.appId == hint.appId && $0.sourceKind == .dockHint }

            if let idx = items.firstIndex(where: { $0.id == hintId }) {
                if items[idx].unreadBadgeText != hint.badgeText {
                    items[idx].unreadBadgeText = hint.badgeText
                    items[idx].body = "该工作区有 \(hint.badgeText) 条未读消息，点击直接切换查看"
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
                    body: "该工作区有 \(hint.badgeText) 条未读消息，点击直接切换查看",
                    unreadBadgeText: hint.badgeText,
                    hasMentionBreakthrough: false,
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

        // Update ephemeral suppressed muted items drawer cleanly
        if suppressedMutedItems != nextSuppressedMuted {
            suppressedMutedItems = nextSuppressedMuted
            if nextSuppressedMuted.isEmpty && showMutedDrawer {
                showMutedDrawer = false
            }
            if isExpanded {
                onLayoutNeedsUpdate?(false)
            }
        }

        // D. Honest Dock Badge Clear & Fallback Coverage
        for monitored in enabledApps {
            let appId = monitored.id
            let reading = obs.dockBadges[appId] ?? .unavailable

            switch reading {
            case .unavailable:
                break

            case .clear:
                // Whenever Dock AXStatusLabel is clear (0), remove dock hints and any stale (>3.5s) non-snoozed
                // notifications/rows without @我 — even on the very first startup scan!
                let before = items.count
                items.removeAll { item in
                    guard item.appId == appId, item.sourceKind != .demo, !item.isSnoozed(at: current) else {
                        return false
                    }
                    if item.sourceKind == .dockHint || item.sourceKind == .tenantHint {
                        return true
                    }
                    if item.hasMentionBreakthrough {
                        return false
                    }
                    return current.timeIntervalSince(item.latestActivityAt) >= 3.5
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
                        ? "检测到角标（\(reading.displayText)），展开\(monitored.displayName)窗口可自动定位具体会话"
                        : "检测到未读角标（\(reading.displayText)），点击打开\(monitored.displayName)查看"

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
                            hasMentionBreakthrough: false,
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

        let presenceChanged = (prevHadPresence != hasUnresolvedAggregatePresence)
        if mutated || presenceChanged {
            if mutated { savePersistedState() }
            onStatusItemNeedsUpdate?()
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
            if isExpanded && !isPinnedExpanded {
                collapsePanel()
            }
            return
        }

        let outcome = onJumpRequested?(item, appObj) ?? .appActivatedNeedsConfirm
        let isFromMutedDrawer = suppressedMutedItems.contains(where: { $0.id == item.id })

        if isFromMutedDrawer {
            if isExpanded && !isPinnedExpanded {
                collapsePanel()
            }
            return
        }

        if outcome.resolvedConversationDirectly {
            completeItem(item, undoLabel: "已定位「\(item.sender)」")
        } else {
            showNotice(outcome.feedbackText(appName: appObj.displayName))
            if case .incoming(let peekItem) = activePeek, peekItem.id == item.id {
                dismissPeek()
            }
        }

        if isExpanded && !isPinnedExpanded {
            collapsePanel()
        }
    }

    func completeItem(_ item: MessageItem, undoLabel: String? = nil) {
        items.removeAll { $0.id == item.id }
        if expandedBodyItemId == item.id { expandedBodyItemId = nil }
        recordHandledRevision(id: item.id, revision: item.contentRevision)
        savePersistedState()

        if case .incoming(let peekItem) = activePeek, peekItem.id == item.id {
            dismissPeek(notifyLayout: false)
        }
        presentUndo(UndoSnapshot(items: [item], mutedRule: nil, label: undoLabel ?? "已完成「\(item.sender)」"))
        onStatusItemNeedsUpdate?()
        onLayoutNeedsUpdate?(true)
    }

    func snooze(_ item: MessageItem, minutes: Int = 15) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        items[idx].lastNotifiedOverdueAt = nil
        if expandedBodyItemId == item.id { expandedBodyItemId = nil }
        savePersistedState()

        if case .incoming(let peekItem) = activePeek, peekItem.id == item.id {
            dismissPeek(notifyLayout: false)
        }
        let durationText = minutes >= 60 ? "\(minutes / 60) 小时" : "\(minutes) 分钟"
        showNotice("已稍后提醒（\(durationText)）：\(item.sender)")
        onStatusItemNeedsUpdate?()
        onLayoutNeedsUpdate?(true)
    }

    func snoozeUntilTomorrowMorning(_ item: MessageItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let cal = Calendar.current
        let current = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: current)
        comps.hour = 9
        comps.minute = 30
        comps.second = 0
        var target = cal.date(from: comps) ?? current.addingTimeInterval(12 * 3600)
        if target.timeIntervalSince(current) < 3600 {
            target = cal.date(byAdding: .day, value: 1, to: target) ?? current.addingTimeInterval(14 * 3600)
        }
        items[idx].snoozedUntil = target
        items[idx].lastNotifiedOverdueAt = nil
        if expandedBodyItemId == item.id { expandedBodyItemId = nil }
        savePersistedState()

        if case .incoming(let peekItem) = activePeek, peekItem.id == item.id {
            dismissPeek(notifyLayout: false)
        }
        showNotice("已延后至明早 09:30：\(item.sender)")
        onStatusItemNeedsUpdate?()
        onLayoutNeedsUpdate?(true)
    }

    func undoLastAction() {
        guard let snap = undoBanner else { return }
        undoDismissTask?.cancel()
        undoBanner = nil
        if let rule = snap.mutedRule {
            mutedRules.removeAll { $0 == rule }
        }
        for restored in snap.items {
            removeHandledRevision(id: restored.id)
            if !items.contains(where: { $0.id == restored.id }) {
                items.append(restored)
            }
        }
        savePersistedState()
        if snap.mutedRule != nil {
            onMonitoredAppsChanged?(monitoredApps)
        }
        onStatusItemNeedsUpdate?()
        onLayoutNeedsUpdate?(true)
    }

    func clearVisibleCompleted() {
        let targets = displayedQueueItems
        guard !targets.isEmpty else { return }
        for t in targets {
            recordHandledRevision(id: t.id, revision: t.contentRevision)
        }
        let ids = Set(targets.map(\.id))
        items.removeAll { ids.contains($0.id) }
        expandedBodyItemId = nil
        savePersistedState()
        presentUndo(UndoSnapshot(items: targets, mutedRule: nil, label: "已将 \(targets.count) 项全部标为已阅"))
        onStatusItemNeedsUpdate?()
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
            showMutedDrawer = false
            expandedBodyItemId = nil
        }
        onLayoutNeedsUpdate?(true)
    }

    func expandPanelAndFocus() {
        if !isExpanded {
            isExpanded = true
            selectedKeyboardIndex = 0
            showSnoozedSheet = false
            dismissPeek(notifyLayout: false)
        }
        onLayoutNeedsUpdate?(true)
    }

    func collapsePanel() {
        guard isExpanded else { return }
        isExpanded = false
        showSettings = false
        showMutedDrawer = false
        expandedBodyItemId = nil
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
            try? await Task.sleep(nanoseconds: 5_500_000_000)
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
        if let savedOrder = decoded.handledRevisionOrder, !savedOrder.isEmpty {
            self.handledRevisionOrder = savedOrder.filter { decoded.handledRevisions[$0] != nil }
        } else {
            self.handledRevisionOrder = Array(decoded.handledRevisions.keys)
        }
        self.seenNotificationKeys = Set(decoded.seenNotificationKeys.suffix(400))
        self.mutedRules = decoded.mutedRules
    }

    private func savePersistedState() {
        if handledRevisionOrder.count > 300 || handledRevisions.count > 300 {
            let keepOrder = Array(handledRevisionOrder.suffix(220))
            var trimmed: [String: String] = [:]
            for k in keepOrder {
                if let val = handledRevisions[k] {
                    trimmed[k] = val
                }
            }
            handledRevisions = trimmed
            handledRevisionOrder = keepOrder.filter { trimmed[$0] != nil }
        }
        let nonDemoItems = items.filter { $0.sourceKind != .demo }
        let state = PersistedQueueState(
            items: nonDemoItems,
            handledRevisions: handledRevisions,
            handledRevisionOrder: handledRevisionOrder,
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
            body: "@你 下午客户演示环境好了吗？看到回一下，顺便把最新接口变更清单发群里",
            unreadBadgeText: "2",
            hasMentionBreakthrough: true,
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
            body: "合同盖章扫描件发你了，麻烦确认下收件信息与发票抬头是否正确",
            unreadBadgeText: "1",
            hasMentionBreakthrough: false,
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
            hasMentionBreakthrough: false,
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
        onStatusItemNeedsUpdate?()
        if !isExpanded {
            presentPeek(.incoming(demoQQ), durationSeconds: 4.5)
        } else {
            onLayoutNeedsUpdate?(true)
        }
    }
}

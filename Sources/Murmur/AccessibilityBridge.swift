import AppKit
import ApplicationServices
import Foundation

struct AXWorldObservation {
    let trusted: Bool
    let dockBadges: [String: DockBadgeReading]
    let conversations: [ConversationSnapshot]
    let readableSidebarAppIds: Set<String>
    let activeTenantByAppId: [String: String]
    let tenantHints: [TenantBadgeHint]
    let liveSystemBanners: [ConversationSnapshot]
}

final class AccessibilityBridge {
    private let axQueue = DispatchQueue(label: "io.github.deep-octopus.Murmur.ax", qos: .utility)
    private var pollTimer: Timer?
    private var enabledExtendedPIDs: [pid_t: TimeInterval] = [:]
    private var ncObserver: AXObserver?
    private var observedNCPid: pid_t = 0
    private var monitoredApps: [MonitoredApp]

    private let onObservation: (AXWorldObservation) -> Void

    init(
        initialApps: [MonitoredApp],
        onObservation: @escaping (AXWorldObservation) -> Void
    ) {
        self.monitoredApps = initialApps.filter(\.isEnabled)
        self.onObservation = onObservation
    }

    func updateMonitoredApps(_ apps: [MonitoredApp]) {
        axQueue.async { [weak self] in
            guard let self else { return }
            self.monitoredApps = apps.filter(\.isEnabled)
            let obs = self.scanWorld()
            DispatchQueue.main.async {
                self.onObservation(obs)
            }
        }
    }

    static func isTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    static func openAccessibilitySettings() {
        _ = isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func relaunchCurrentBundle() {
        let targetURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.35 && open \"\(targetURL.path)\""]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    func startPolling() {
        triggerScan()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { [weak self] _ in
            self?.triggerScan()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        teardownNotificationCenterObserver()
    }

    func triggerScan() {
        if Self.isTrusted(prompt: false) {
            DispatchQueue.main.async { [weak self] in
                self?.ensureNotificationCenterObserverInstalled()
            }
        }
        axQueue.async { [weak self] in
            guard let self else { return }
            let obs = self.scanWorld()
            DispatchQueue.main.async {
                self.onObservation(obs)
            }
        }
    }

    private func ensureNotificationCenterObserverInstalled() {
        guard let ncApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            return
        }
        let pid = ncApp.processIdentifier
        guard pid != observedNCPid || ncObserver == nil else { return }

        teardownNotificationCenterObserver()

        let callback: AXObserverCallback = { (_, _, _, refcon) in
            guard let refcon else { return }
            let bridge = Unmanaged<AccessibilityBridge>.fromOpaque(refcon).takeUnretainedValue()
            bridge.axQueue.asyncAfter(deadline: .now() + 0.08) {
                let banners = bridge.scanNotificationCenterBanners(apps: bridge.monitoredApps)
                    + bridge.scanHelperBannerWindows(apps: bridge.monitoredApps)
                guard !banners.isEmpty else { return }
                let obs = bridge.scanWorld()
                DispatchQueue.main.async {
                    bridge.onObservation(obs)
                }
            }
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let ncRoot = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        AXObserverAddNotification(obs, ncRoot, kAXLayoutChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, ncRoot, kAXCreatedNotification as CFString, refcon)
        AXObserverAddNotification(obs, ncRoot, kAXWindowCreatedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        self.ncObserver = obs
        self.observedNCPid = pid
    }

    private func teardownNotificationCenterObserver() {
        if let obs = ncObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            ncObserver = nil
        }
        observedNCPid = 0
    }

    // MARK: - Full Background Scan Across All Enabled MonitoredApps

    private func scanWorld() -> AXWorldObservation {
        let apps = self.monitoredApps
        let trusted = Self.isTrusted(prompt: false)
        guard trusted else {
            var unavailable: [String: DockBadgeReading] = [:]
            for app in apps { unavailable[app.id] = .unavailable }
            return AXWorldObservation(
                trusted: false,
                dockBadges: unavailable,
                conversations: [],
                readableSidebarAppIds: [],
                activeTenantByAppId: [:],
                tenantHints: [],
                liveSystemBanners: []
            )
        }

        let dockBadges = readDockBadges(apps: apps)
        var allConversations: [ConversationSnapshot] = []
        var readableAppIds: Set<String> = []
        var activeTenantByApp: [String: String] = [:]
        var allTenantHints: [TenantBadgeHint] = []

        for monitored in apps {
            guard let running = findRunningMainApp(for: monitored) else { continue }
            let pid = running.processIdentifier
            let appRef = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appRef, 0.35)

            ensureExtendedAccessibilityEnabled(app: running, appRef: appRef)

            guard let windows = copyElementArrayAttr(of: appRef, attr: kAXWindowsAttribute as String),
                  !windows.isEmpty else {
                continue
            }

            let candidateWindows = windows.filter { !isWindowMinimized($0) }
            guard let mainWin = pickPrimaryWindow(from: candidateWindows) else { continue }

            var activeTenant: String? = nil
            if monitored.supportsTenantRail {
                let rail = scanTenantRail(window: mainWin, appId: monitored.id)
                allTenantHints.append(contentsOf: rail.tenants)
                activeTenant = rail.selectedTenantName
                if let activeTenant, !activeTenant.isEmpty {
                    activeTenantByApp[monitored.id] = activeTenant
                }
            }

            let sidebarResult = scanUnreadConversations(
                in: mainWin,
                appId: monitored.id,
                tenantName: activeTenant,
                pid: pid
            )

            if sidebarResult.foundConversationContainer {
                readableAppIds.insert(monitored.id)
            }
            allConversations.append(contentsOf: sidebarResult.unreadRows)
        }

        let liveBanners = scanNotificationCenterBanners(apps: apps) + scanHelperBannerWindows(apps: apps)

        return AXWorldObservation(
            trusted: true,
            dockBadges: dockBadges,
            conversations: allConversations,
            readableSidebarAppIds: readableAppIds,
            activeTenantByAppId: activeTenantByApp,
            tenantHints: allTenantHints,
            liveSystemBanners: liveBanners
        )
    }

    private func ensureExtendedAccessibilityEnabled(app: NSRunningApplication, appRef: AXUIElement) {
        let launchStamp = app.launchDate?.timeIntervalSince1970 ?? 0
        if enabledExtendedPIDs[app.processIdentifier] == launchStamp {
            return
        }
        let r1 = AXUIElementSetAttributeValue(appRef, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let r2 = AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        if r1 == .success || r2 == .success {
            enabledExtendedPIDs[app.processIdentifier] = launchStamp
        }
    }

    // MARK: - 1. Honest Dock Badge Inspection (Truth Anchor for Unmuted Counts!)

    private func readDockBadges(apps: [MonitoredApp]) -> [String: DockBadgeReading] {
        var result: [String: DockBadgeReading] = [:]
        for app in apps { result[app.id] = .unavailable }

        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return result
        }

        let dockRef = AXUIElementCreateApplication(dockApp.processIdentifier)
        AXUIElementSetMessagingTimeout(dockRef, 0.30)
        guard let topChildren = copyChildren(of: dockRef) else {
            return result
        }

        for listEl in topChildren {
            guard let items = copyChildren(of: listEl) else { continue }
            for tile in items {
                let title = copyStringAttr(of: tile, attr: kAXTitleAttribute as String) ?? ""
                let tileBundleId = copyTileBundleIdentifier(tile) ?? ""

                for app in apps {
                    let matchedByBundle = !tileBundleId.isEmpty && app.matchesBundleId(tileBundleId)
                    let matchedByTitle = !title.isEmpty && app.matchesAppLabel(title)
                    if matchedByBundle || matchedByTitle {
                        let rawBadge = copyStringAttr(of: tile, attr: "AXStatusLabel") ?? ""
                        result[app.id] = parseDockBadge(rawBadge)
                    }
                }
            }
        }
        return result
    }

    private func copyTileBundleIdentifier(_ tile: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tile, kAXURLAttribute as CFString, &ref) == .success, let ref else {
            return nil
        }
        if let url = ref as? URL {
            return Bundle(url: url)?.bundleIdentifier
        }
        return nil
    }

    private func parseDockBadge(_ raw: String) -> DockBadgeReading {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .clear }
        let digits = trimmed.filter { $0.isNumber }
        if let n = Int(digits), n > 0 {
            if trimmed.contains("+") || trimmed.contains("…") {
                return .atLeast(n)
            }
            return .count(n)
        }
        return .dot
    }

    // MARK: - 2. Multi-Workspace / Multi-Tenant Left Rail Scanner

    private func scanTenantRail(window: AXUIElement, appId: String) -> (tenants: [TenantBadgeHint], selectedTenantName: String?) {
        guard let winPos = copyPosition(of: window), let winSize = copySize(of: window), winSize.width >= 420 else {
            return ([], nil)
        }

        var railNodes: [AXUIElement] = []
        var visited = 0
        collectRailItems(el: window, winX: winPos.x, winY: winPos.y, depth: 0, visited: &visited, into: &railNodes)

        var hints: [TenantBadgeHint] = []
        var selectedName: String? = nil
        var seenNames: Set<String> = []

        for node in railNodes {
            var summary = SubtreeInspection()
            var leafBudget = 0
            inspectSubtree(under: node, depth: 0, visited: &leafBudget, into: &summary)

            let directTitle = copyStringAttr(of: node, attr: kAXTitleAttribute as String)
                ?? copyStringAttr(of: node, attr: kAXDescriptionAttribute as String)
                ?? copyStringAttr(of: node, attr: kAXHelpAttribute as String)
                ?? ""

            let isSelected = copyBoolAttr(of: node, attr: kAXSelectedAttribute as String) == true

            var badgeFound: String? = nil
            var isDotBadge = false
            var candidateNames: [String] = []

            if !directTitle.isEmpty {
                let parsed = extractAccessibilityUnreadLabel(from: directTitle)
                if let b = parsed.badge {
                    badgeFound = b
                    isDotBadge = (b == "有未读")
                }
                if !parsed.cleanName.isEmpty { candidateNames.append(parsed.cleanName) }
            }

            for leaf in summary.leaves {
                if let b = classifyStandaloneBadgeText(leaf.text) {
                    if badgeFound == nil {
                        badgeFound = b
                        isDotBadge = (b == "有未读")
                    }
                } else if !Self.isNavigationTabLabel(leaf.text) {
                    candidateNames.append(leaf.text)
                }
            }

            let rawName = candidateNames.first(where: { $0.count >= 2 && !Self.isNavigationTabLabel($0) }) ?? ""
            guard !rawName.isEmpty, !seenNames.contains(rawName) else { continue }
            seenNames.insert(rawName)

            if isSelected && selectedName == nil {
                selectedName = rawName
            }
            if let badge = badgeFound {
                hints.append(
                    TenantBadgeHint(
                        appId: appId,
                        tenantName: rawName,
                        badgeText: badge,
                        isDotOnly: isDotBadge || summary.hasMuteMetadata,
                        isSelected: isSelected
                    )
                )
            }
        }

        return (hints, selectedName)
    }

    private func collectRailItems(
        el: AXUIElement,
        winX: CGFloat,
        winY: CGFloat,
        depth: Int,
        visited: inout Int,
        into out: inout [AXUIElement]
    ) {
        guard depth <= 22, visited < 1600 else { return }
        visited += 1

        if let pos = copyPosition(of: el), let sz = copySize(of: el) {
            let relX = pos.x - winX
            let relY = pos.y - winY
            if relX > 105 && sz.width < 500 && depth > 4 { return }

            let role = copyStringAttr(of: el, attr: kAXRoleAttribute as String) ?? ""
            if relX >= 0 && relX <= 84 && relY >= 12
                && sz.width >= 26 && sz.width <= 78
                && sz.height >= 26 && sz.height <= 78
                && ["AXButton", "AXGroup", "AXRadioButton", "AXRow", "AXLink", "AXGenericElement"].contains(role) {
                out.append(el)
                return
            }
        }

        guard let children = copyChildren(of: el) else { return }
        for c in children {
            collectRailItems(el: c, winX: winX, winY: winY, depth: depth + 1, visited: &visited, into: &out)
        }
    }

    private static func isNavigationTabLabel(_ text: String) -> Bool {
        let navLabels: Set<String> = [
            "消息", "日历", "云文档", "工作台", "通讯录", "多维表格", "会议", "妙记", "邮箱", "任务", "知识库", "更多",
            "Chats", "Messenger", "Calendar", "Docs", "Workplace", "Contacts", "Meetings", "Mail", "Tasks", "DMs", "Activity"
        ]
        return navLabels.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Built-in folded/muted/feed aggregator folders in Chinese & global IM sidebars
    static func isNoiseAggregatorFolder(_ title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let aggregators: Set<String> = [
            "消息免打扰", "免打扰", "免打扰的群聊", "折叠的群聊", "折叠的会话", "不常联系群聊", "群助手",
            "订阅号", "订阅号消息", "服务号", "公众号", "腾讯新闻", "QQ看点", "好友动态", "迷你世界",
            "Muted Chats", "Collapsed Chats", "Archived", "Archived Chats"
        ]
        return aggregators.contains(clean)
    }

    static func containsMentionBreakthrough(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signals = [
            "@我", "有人@我", "有人@你", "[有人@我]", "[@我]", "@所有人", "@全体成员",
            "@all", "@here", "@channel", "[特别关注]", "[加急]", "[紧急]", "[催办]", "mentioned you"
        ]
        return signals.contains { lower.contains($0) }
    }

    // MARK: - 3. Per-Conversation Sidebar Unread Scanner (With Muted vs Unmuted Signal Separation!)

    private struct LeafNode {
        let text: String
        let pos: CGPoint
        let size: CGSize
    }

    private struct SubtreeInspection {
        var leaves: [LeafNode] = []
        var hasMuteMetadata: Bool = false
        var hasMentionSignal: Bool = false
    }

    private func scanUnreadConversations(
        in window: AXUIElement,
        appId: String,
        tenantName: String?,
        pid: pid_t
    ) -> (unreadRows: [ConversationSnapshot], foundConversationContainer: Bool) {
        guard let winPos = copyPosition(of: window), let winSize = copySize(of: window), winSize.width >= 280 else {
            return ([], false)
        }

        var rowElements: [AXUIElement] = []
        var visited = 0
        collectCandidateSessionRows(
            el: window,
            winX: winPos.x,
            winWidth: winSize.width,
            depth: 0,
            visited: &visited,
            into: &rowElements
        )

        let foundContainer = rowElements.count >= 2
        var unreadSnapshots: [ConversationSnapshot] = []
        var seenTitles: Set<String> = []

        for rowEl in rowElements {
            if let snap = parseCandidateRow(
                rowEl,
                appId: appId,
                tenantName: tenantName,
                pid: pid
            ), !seenTitles.contains(snap.title) {
                seenTitles.insert(snap.title)
                unreadSnapshots.append(snap)
            }
        }

        return (unreadSnapshots, foundContainer)
    }

    private func collectCandidateSessionRows(
        el: AXUIElement,
        winX: CGFloat,
        winWidth: CGFloat,
        depth: Int,
        visited: inout Int,
        into out: inout [AXUIElement]
    ) {
        guard depth <= 28, visited < 5500, out.count < 65 else { return }
        visited += 1

        if let pos = copyPosition(of: el), let sz = copySize(of: el) {
            let relX = pos.x - winX
            let maxSidebarStart = max(260.0, min(460.0, winWidth * 0.46))
            if relX > maxSidebarStart && sz.width < winWidth * 0.65 && depth > 4 {
                return
            }

            let role = copyStringAttr(of: el, attr: kAXRoleAttribute as String) ?? ""
            let isRowRole = ["AXRow", "AXCell", "AXGroup", "AXButton", "AXLink", "AXGenericElement", "AXCheckBox", "AXRadioButton"].contains(role)
            let isRowShape = relX >= 0 && relX <= maxSidebarStart
                && sz.width >= 145 && sz.width <= 540
                && sz.height >= 36 && sz.height <= 124
                && isRowRole

            if isRowShape {
                let childRowCount = (copyChildren(of: el) ?? []).filter { child in
                    guard let csz = copySize(of: child) else { return false }
                    return csz.width >= 145 && csz.height >= 36 && csz.height < sz.height - 16
                }.count
                if childRowCount == 0 {
                    out.append(el)
                    return
                }
            }
        }

        guard let children = copyChildren(of: el) else { return }
        for c in children {
            collectCandidateSessionRows(
                el: c,
                winX: winX,
                winWidth: winWidth,
                depth: depth + 1,
                visited: &visited,
                into: &out
            )
        }
    }

    private func parseCandidateRow(
        _ rowEl: AXUIElement,
        appId: String,
        tenantName: String?,
        pid: pid_t
    ) -> ConversationSnapshot? {
        var inspection = SubtreeInspection()
        var visited = 0
        inspectSubtree(under: rowEl, depth: 0, visited: &visited, into: &inspection)
        guard !inspection.leaves.isEmpty else { return nil }

        let rowDesc = copyStringAttr(of: rowEl, attr: kAXDescriptionAttribute as String) ?? ""
        let rowTitle = copyStringAttr(of: rowEl, attr: kAXTitleAttribute as String) ?? ""

        var standaloneBadge: String? = nil
        var inlineMutedPrefixBadge: String? = nil
        var mentionFound = inspection.hasMentionSignal
            || Self.containsMentionBreakthrough(rowDesc)
            || Self.containsMentionBreakthrough(rowTitle)

        // 1. Check explicit "N条未读" / "unread" accessibility label on row wrapper (NOT bare "3条"!)
        for rawCombined in [rowDesc, rowTitle] where !rawCombined.isEmpty {
            let extracted = extractAccessibilityUnreadLabel(from: rawCombined)
            if let b = extracted.badge {
                standaloneBadge = b
            }
        }

        let sortedLeaves = inspection.leaves.sorted { a, b in
            if abs(a.pos.y - b.pos.y) > 8 {
                return a.pos.y < b.pos.y
            }
            return a.pos.x < b.pos.x
        }

        var contentTexts: [LeafNode] = []
        for leaf in sortedLeaves {
            let txt = leaf.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !txt.isEmpty else { continue }

            if Self.containsMentionBreakthrough(txt) {
                mentionFound = true
            }

            // Explicit accessibility unread label ("3条未读" / "3 unread")
            let explicitLabel = extractAccessibilityUnreadLabel(from: txt)
            if let b = explicitLabel.badge {
                standaloneBadge = standaloneBadge ?? b
                if !explicitLabel.cleanName.isEmpty {
                    contentTexts.append(LeafNode(text: explicitLabel.cleanName, pos: leaf.pos, size: leaf.size))
                }
                continue
            }

            // Leading bracketed muted prefix "[14条] 张三: 哈哈哈" at start of preview leaf!
            let mutedPrefix = extractLeadingMutedCountPrefix(from: txt)
            if let mb = mutedPrefix.badge {
                inlineMutedPrefixBadge = inlineMutedPrefixBadge ?? mb
                if !mutedPrefix.cleanPreview.isEmpty {
                    contentTexts.append(LeafNode(text: mutedPrefix.cleanPreview, pos: leaf.pos, size: leaf.size))
                }
                continue
            }

            // Compact standalone badge pill ("1"..."999", "99+", "@", "•")
            if leaf.size.width <= 54 && leaf.size.height <= 30,
               let pill = classifyStandaloneBadgeText(txt) {
                if pill == "@我" {
                    mentionFound = true
                    standaloneBadge = standaloneBadge ?? "1"
                    continue
                }
                let hasOtherTitleCandidate = sortedLeaves.contains { other in
                    other.text != leaf.text
                        && !Self.looksLikeTimestamp(other.text)
                        && classifyStandaloneBadgeText(other.text) == nil
                }
                if hasOtherTitleCandidate {
                    standaloneBadge = standaloneBadge ?? pill
                    continue
                }
            }

            if Self.looksLikeTimestamp(txt) {
                continue
            }

            contentTexts.append(leaf)
        }

        let finalBadge = standaloneBadge ?? inlineMutedPrefixBadge
        guard let badgeText = finalBadge else {
            return nil
        }

        var title = contentTexts.first?.text ?? ""
        var preview = contentTexts.dropFirst().first(where: { $0.text != title })?.text ?? ""

        if title.isEmpty, !rowDesc.isEmpty {
            let cleaned = extractAccessibilityUnreadLabel(from: rowDesc).cleanName
            let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: "\n,，"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !Self.looksLikeTimestamp($0) }
            title = parts.first ?? ""
            preview = parts.dropFirst().first ?? ""
        } else {
            title = extractAccessibilityUnreadLabel(from: title).cleanName
        }

        guard !title.isEmpty, !Self.isNavigationTabLabel(title) else { return nil }
        if preview.isEmpty {
            preview = badgeText == "有未读" ? "有新消息未读" : "\(badgeText) 条未读消息"
        }

        let isNumericStandalone = (standaloneBadge != nil && standaloneBadge != "有未读")
        let hasMuteEvidence = inspection.hasMuteMetadata
            || Self.isNoiseAggregatorFolder(title)
            || (inlineMutedPrefixBadge != nil)
            || (badgeText == "有未读")

        return ConversationSnapshot(
            appId: appId,
            tenantName: tenantName,
            title: title,
            preview: preview,
            badgeText: badgeText,
            hasStandaloneNumericBadge: isNumericStandalone,
            hasExplicitMuteSignal: hasMuteEvidence,
            hasMentionBreakthrough: mentionFound,
            pid: pid
        )
    }

    private func inspectSubtree(
        under el: AXUIElement,
        depth: Int,
        visited: inout Int,
        into out: inout SubtreeInspection
    ) {
        guard depth <= 13, visited < 160 else { return }
        visited += 1

        let role = copyStringAttr(of: el, attr: kAXRoleAttribute as String) ?? ""
        let helpTxt = copyStringAttr(of: el, attr: kAXHelpAttribute as String) ?? ""
        let descTxt = copyStringAttr(of: el, attr: kAXDescriptionAttribute as String) ?? ""
        let titleTxt = copyStringAttr(of: el, attr: kAXTitleAttribute as String) ?? ""

        // Check Chromium/Electron DOM classes & mute icon accessibility hints
        let domClasses = copyStringArrayAttr(of: el, attr: "AXDOMClassList") ?? []
        let combinedMeta = ([helpTxt, role == "AXImage" ? descTxt : "", role == "AXImage" ? titleTxt : ""] + domClasses)
            .joined(separator: " ")
            .lowercased()

        let muteKeywords = [
            "免打扰", "已静音", "静音", "不提醒", "折叠", "屏蔽",
            "mute", "muted", "silent", "dnd",
            "no-disturb", "not-disturb", "dont-disturb", "do-not-disturb", "disturb-icon", "icon-disturb", "is-disturb",
            "bell-off", "bell_off", "icon-mute", "grey-badge", "gray-badge", "badge-grey", "badge-gray", "badge_gray", "badge_grey"
        ]
        if muteKeywords.contains(where: { combinedMeta.contains($0) }) {
            out.hasMuteMetadata = true
        }
        if domClasses.contains(where: { $0.lowercased().contains("mention") || $0.lowercased().contains("at-me") }) {
            out.hasMentionSignal = true
        }

        let children = copyChildren(of: el) ?? []
        let pos = copyPosition(of: el) ?? .zero
        let sz = copySize(of: el) ?? CGSize(width: 20, height: 16)

        if ["AXStaticText", "AXButton", "AXLink", "AXGenericElement"].contains(role) || (children.isEmpty && role != "AXImage") {
            for attr in [kAXValueAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
                if let val = copyStringAttr(of: el, attr: attr)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !val.isEmpty {
                    out.leaves.append(LeafNode(text: val, pos: pos, size: sz))
                    break
                }
            }
        }

        for c in children {
            inspectSubtree(under: c, depth: depth + 1, visited: &visited, into: &out)
        }
    }

    private func classifyStandaloneBadgeText(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 4 else { return nil }
        if t == "@" { return "@我" }
        if t == "99+" || t == "999+" { return t }
        if t.hasSuffix("+"), let n = Int(t.dropLast()), n > 0 { return t }
        if t.allSatisfy({ $0.isNumber }), let n = Int(t), n >= 1 && n <= 999 {
            return "\(n)"
        }
        if t == "•" || t == "●" { return "有未读" }
        return nil
    }

    /// Strictly matches ONLY explicit unread accessibility labels ("3条未读", "未读消息 3", "3 unread"),
    /// NEVER matching bare "3条" inside normal chat sentences like "这3条数据核对下"!
    private func extractAccessibilityUnreadLabel(from text: String) -> (badge: String?, cleanName: String) {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var badge: String? = nil

        let patterns = [
            #"(\d+\+?)\s*条未读"#,
            #"未读消息?\s*(\d+\+?)"#,
            #"(\d+\+?)\s*unread\b"#
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                let nsRange = NSRange(working.startIndex..<working.endIndex, in: working)
                if let match = regex.firstMatch(in: working, options: [], range: nsRange),
                   let r1 = Range(match.range(at: 1), in: working),
                   let fullR = Range(match.range(at: 0), in: working) {
                    badge = String(working[r1])
                    working.removeSubrange(fullR)
                    break
                }
            }
        }
        if badge == nil && (working.contains("有未读") || working.contains("未读消息")) {
            badge = "有未读"
            working = working.replacingOccurrences(of: "有未读", with: "")
                .replacingOccurrences(of: "未读消息", with: "")
        }

        let cleaned = working.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "·-—:：()[]")))
        return (badge, cleaned)
    }

    /// Matches ONLY bracketed muted-chat count prefixes at the very start of a preview line: `[14条] 张三: 哈哈哈`
    private func extractLeadingMutedCountPrefix(from preview: String) -> (badge: String?, cleanPreview: String) {
        let working = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^\[(\d+\+?)\s*条\]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (nil, working)
        }
        let nsRange = NSRange(working.startIndex..<working.endIndex, in: working)
        guard let match = regex.firstMatch(in: working, options: [], range: nsRange),
              let r1 = Range(match.range(at: 1), in: working),
              let fullR = Range(match.range(at: 0), in: working) else {
            return (nil, working)
        }
        let countStr = String(working[r1])
        var rest = working
        rest.removeSubrange(fullR)
        return (countStr, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func looksLikeTimestamp(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["刚刚", "昨天", "前天", "今天", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日", "周一", "周二", "周三", "周四", "周五", "周六", "周日"].contains(t) {
            return true
        }
        if t.count <= 8 && (t.contains(":") || t.contains("/")) {
            let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ":/- 上午下午AMPMampm"))
            if t.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - 4. Live System NotificationCenter & Helper Banner Readers

    private func scanNotificationCenterBanners(apps: [MonitoredApp]) -> [ConversationSnapshot] {
        guard let ncApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            return []
        }
        let root = AXUIElementCreateApplication(ncApp.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)

        var bannerNodes: [AXUIElement] = []
        var visited = 0
        collectBannerElements(el: root, depth: 0, visited: &visited, into: &bannerNodes)

        var results: [ConversationSnapshot] = []
        for banner in bannerNodes {
            if let snap = parseNotificationBannerElement(banner, apps: apps, pid: ncApp.processIdentifier) {
                results.append(snap)
            }
        }
        return results
    }

    private func collectBannerElements(
        el: AXUIElement,
        depth: Int,
        visited: inout Int,
        into out: inout [AXUIElement]
    ) {
        guard depth <= 9, visited < 260, out.count < 15 else { return }
        visited += 1

        let subrole = copyStringAttr(of: el, attr: kAXSubroleAttribute as String) ?? ""
        if subrole.contains("NotificationCenter") || subrole == "AXBanner" || subrole == "AXAlert" {
            out.append(el)
            return
        }

        guard let children = copyChildren(of: el) else { return }
        for c in children {
            collectBannerElements(el: c, depth: depth + 1, visited: &visited, into: &out)
        }
    }

    private func parseNotificationBannerElement(
        _ banner: AXUIElement,
        apps: [MonitoredApp],
        pid: pid_t
    ) -> ConversationSnapshot? {
        var inspection = SubtreeInspection()
        var visited = 0
        inspectSubtree(under: banner, depth: 0, visited: &visited, into: &inspection)

        var parts = inspection.leaves.map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !["关闭", "回复", "选项", "清除", "Close", "Reply", "Options"].contains($0) && !Self.looksLikeTimestamp($0) }

        if parts.count < 2 {
            let desc = copyStringAttr(of: banner, attr: kAXDescriptionAttribute as String)
                ?? copyStringAttr(of: banner, attr: "AXAttributedDescription")
                ?? copyStringAttr(of: banner, attr: kAXTitleAttribute as String)
                ?? ""
            let split = desc.components(separatedBy: CharacterSet(charactersIn: "\n,，"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !Self.looksLikeTimestamp($0) }
            if split.count > parts.count {
                parts = split
            }
        }

        guard !parts.isEmpty else { return nil }

        var matchedApp: MonitoredApp? = nil
        var contentParts: [String] = []

        for part in parts {
            if matchedApp == nil, let app = apps.first(where: { $0.matchesAppLabel(part) }) {
                matchedApp = app
                continue
            }
            contentParts.append(part)
        }

        guard let targetApp = matchedApp else { return nil }
        let sender = contentParts.first ?? targetApp.displayName
        let body = contentParts.dropFirst().joined(separator: " · ")

        return ConversationSnapshot(
            appId: targetApp.id,
            tenantName: nil,
            title: sender,
            preview: body.isEmpty ? "发来一条新消息" : body,
            badgeText: "1",
            hasStandaloneNumericBadge: true,
            hasExplicitMuteSignal: false,
            hasMentionBreakthrough: Self.containsMentionBreakthrough(body) || Self.containsMentionBreakthrough(sender),
            pid: pid
        )
    }

    private func scanHelperBannerWindows(apps: [MonitoredApp]) -> [ConversationSnapshot] {
        var banners: [ConversationSnapshot] = []
        for app in apps where !app.helperBundleIds.isEmpty {
            for helperBid in app.helperBundleIds {
                guard let notifier = NSRunningApplication.runningApplications(withBundleIdentifier: helperBid).first else {
                    continue
                }
                let appRef = AXUIElementCreateApplication(notifier.processIdentifier)
                AXUIElementSetMessagingTimeout(appRef, 0.25)
                _ = AXUIElementSetAttributeValue(appRef, "AXManualAccessibility" as CFString, kCFBooleanTrue)

                guard let windows = copyElementArrayAttr(of: appRef, attr: kAXWindowsAttribute as String), !windows.isEmpty else {
                    continue
                }
                for win in windows {
                    var inspection = SubtreeInspection()
                    var visited = 0
                    inspectSubtree(under: win, depth: 0, visited: &visited, into: &inspection)
                    let texts = inspection.leaves.map(\.text).filter { !$0.isEmpty && $0 != "关闭" && $0 != "回复" }
                    guard texts.count >= 2 else { continue }
                    let preview = texts.dropFirst().joined(separator: " · ")
                    banners.append(
                        ConversationSnapshot(
                            appId: app.id,
                            tenantName: nil,
                            title: texts[0],
                            preview: preview,
                            badgeText: "1",
                            hasStandaloneNumericBadge: true,
                            hasExplicitMuteSignal: false,
                            hasMentionBreakthrough: Self.containsMentionBreakthrough(preview) || Self.containsMentionBreakthrough(texts[0]),
                            pid: notifier.processIdentifier
                        )
                    )
                }
            }
        }
        return banners
    }

    // MARK: - 5. Verified Session & Tenant Jump Router

    func jumpToItem(_ item: MessageItem, app: MonitoredApp) -> JumpOutcome {
        let trusted = Self.isTrusted(prompt: false)

        if item.sourceKind == .tenantHint, let tenant = item.tenantName, !tenant.isEmpty {
            guard let runningApp = findRunningMainApp(for: app) else {
                launchMainApp(for: app)
                return .appLaunched
            }
            activateAndRaise(app: runningApp)
            if trusted, trySelectTenant(pid: runningApp.processIdentifier, tenantName: tenant).matched {
                return .tenantSwitched(tenant)
            }
            return .appActivatedNeedsConfirm
        }

        if trusted && item.sourceKind == .notification {
            if tryClickNotificationCenterBanner(matching: item, appName: app.displayName) {
                return .conversationOpened
            }
        }

        guard let runningApp = findRunningMainApp(for: app) else {
            launchMainApp(for: app)
            return .appLaunched
        }

        activateAndRaise(app: runningApp)
        guard trusted else {
            return .appActivatedNeedsConfirm
        }

        let pid = runningApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, 0.40)
        ensureExtendedAccessibilityEnabled(app: runningApp, appRef: appRef)

        var didSwitchTenant = false
        if app.supportsTenantRail, let targetTenant = item.tenantName, !targetTenant.isEmpty {
            didSwitchTenant = trySelectTenant(pid: pid, tenantName: targetTenant).switchedNew
        }

        if item.sourceKind != .dockHint {
            usleep(didSwitchTenant ? 220_000 : 50_000)
            // Try matching sender first, then subtitle (e.g. group name when notification title was individual sender)
            var candidates = [item.sender]
            if !item.subtitle.isEmpty && item.subtitle != item.tenantName {
                candidates.append(item.subtitle)
            }
            for target in candidates {
                if tryPressVerifiedSidebarConversation(pid: pid, exactTitle: target) {
                    return .conversationOpened
                }
            }
        }

        return .appActivatedNeedsConfirm
    }

    func openAppDirectly(_ app: MonitoredApp) {
        if let running = findRunningMainApp(for: app) {
            activateAndRaise(app: running)
        } else {
            launchMainApp(for: app)
        }
    }

    private func findRunningMainApp(for app: MonitoredApp) -> NSRunningApplication? {
        for bid in app.mainBundleIds {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                return running
            }
        }
        return nil
    }

    private func launchMainApp(for app: MonitoredApp) {
        for bid in app.mainBundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                return
            }
        }
    }

    private func activateAndRaise(app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        NSApp.yieldActivation(to: app)
        app.activate(options: [.activateAllWindows])

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appRef, 0.30)
        guard let windows = copyElementArrayAttr(of: appRef, attr: kAXWindowsAttribute as String),
              !windows.isEmpty else { return }

        for win in windows where isWindowMinimized(win) {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            break
        }
        if let primary = pickPrimaryWindow(from: windows) {
            AXUIElementPerformAction(primary, kAXRaiseAction as CFString)
        }
    }

    private func trySelectTenant(pid: pid_t, tenantName: String) -> (matched: Bool, switchedNew: Bool) {
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, 0.35)
        guard let windows = copyElementArrayAttr(of: appRef, attr: kAXWindowsAttribute as String),
              let mainWin = pickPrimaryWindow(from: windows),
              let winPos = copyPosition(of: mainWin) else { return (false, false) }

        var railNodes: [AXUIElement] = []
        var visited = 0
        collectRailItems(el: mainWin, winX: winPos.x, winY: winPos.y, depth: 0, visited: &visited, into: &railNodes)

        for node in railNodes {
            let blob = collectText(under: node, maxDepth: 4)
            if blob.contains(tenantName) {
                if copyBoolAttr(of: node, attr: kAXSelectedAttribute as String) == true {
                    return (true, false)
                }
                if AXUIElementPerformAction(node, kAXPressAction as CFString) == .success {
                    return (true, true)
                }
            }
        }
        return (false, false)
    }

    private func tryClickNotificationCenterBanner(matching item: MessageItem, appName: String) -> Bool {
        guard let ncApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            return false
        }
        let root = AXUIElementCreateApplication(ncApp.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.30)
        let senderNeedle = item.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !senderNeedle.isEmpty, senderNeedle != appName else { return false }

        var visited = 0
        return searchAndPressBanner(element: root, senderNeedle: senderNeedle, depth: 0, visited: &visited)
    }

    private func searchAndPressBanner(
        element: AXUIElement,
        senderNeedle: String,
        depth: Int,
        visited: inout Int
    ) -> Bool {
        guard depth <= 9, visited < 280 else { return false }
        visited += 1

        let subrole = copyStringAttr(of: element, attr: kAXSubroleAttribute as String) ?? ""
        if subrole.contains("NotificationCenter") || subrole == "AXBanner" || subrole == "AXAlert" {
            let textBlob = collectText(under: element, maxDepth: 4)
            if textBlob.contains(senderNeedle) {
                if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                    return true
                }
            }
        }

        guard let children = copyChildren(of: element) else { return false }
        for child in children {
            if searchAndPressBanner(element: child, senderNeedle: senderNeedle, depth: depth + 1, visited: &visited) {
                return true
            }
        }
        return false
    }

    private static func stripGroupMemberSuffix(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"\s*[\(（]\d+[\)）]$"#, options: []) else {
            return trimmed
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return regex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "")
    }

    private func tryPressVerifiedSidebarConversation(pid: pid_t, exactTitle: String) -> Bool {
        let cleanTarget = Self.stripGroupMemberSuffix(exactTitle)
        guard !cleanTarget.isEmpty else { return false }

        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, 0.35)
        guard let windows = copyElementArrayAttr(of: appRef, attr: kAXWindowsAttribute as String),
              let mainWin = pickPrimaryWindow(from: windows),
              let winPos = copyPosition(of: mainWin),
              let winSize = copySize(of: mainWin) else { return false }

        var candidateRows: [AXUIElement] = []
        var visited = 0
        collectCandidateSessionRows(
            el: mainWin,
            winX: winPos.x,
            winWidth: winSize.width,
            depth: 0,
            visited: &visited,
            into: &candidateRows
        )

        for rowEl in candidateRows {
            var inspection = SubtreeInspection()
            var v = 0
            inspectSubtree(under: rowEl, depth: 0, visited: &v, into: &inspection)
            let rowDesc = copyStringAttr(of: rowEl, attr: kAXDescriptionAttribute as String) ?? ""
            let rowTitle = copyStringAttr(of: rowEl, attr: kAXTitleAttribute as String) ?? ""

            let exactLeafMatch = inspection.leaves.contains { leaf in
                let cleaned = Self.stripGroupMemberSuffix(extractAccessibilityUnreadLabel(from: leaf.text).cleanName)
                return cleaned == cleanTarget
            }
            let exactHeaderMatch = Self.stripGroupMemberSuffix(extractAccessibilityUnreadLabel(from: rowTitle).cleanName) == cleanTarget
                || rowDesc.components(separatedBy: CharacterSet(charactersIn: "\n,， ")).contains(cleanTarget)

            guard exactLeafMatch || exactHeaderMatch else { continue }

            let actions = copyActionNames(of: rowEl)
            if actions.contains(kAXPressAction as String) {
                if AXUIElementPerformAction(rowEl, kAXPressAction as CFString) == .success {
                    return true
                }
            }
            if AXUIElementSetAttributeValue(rowEl, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
                return true
            }
            if AXUIElementPerformAction(rowEl, kAXPressAction as CFString) == .success {
                return true
            }
        }
        return false
    }

    // MARK: - Low-Level AX Helpers

    private func pickPrimaryWindow(from windows: [AXUIElement]) -> AXUIElement? {
        guard !windows.isEmpty else { return nil }
        let realWindows = windows.filter { win in
            guard let sz = copySize(of: win) else { return false }
            return sz.width >= 260 && sz.height >= 240
        }
        let pool = realWindows.isEmpty ? windows : realWindows
        return pool.max { a, b in
            let sa = copySize(of: a) ?? .zero
            let sb = copySize(of: b) ?? .zero
            return (sa.width * sa.height) < (sb.width * sb.height)
        }
    }

    private func isWindowMinimized(_ win: AXUIElement) -> Bool {
        copyBoolAttr(of: win, attr: kAXMinimizedAttribute as String) == true
    }

    private func copyActionNames(of element: AXUIElement) -> [String] {
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(element, &namesRef) == .success,
              let arr = namesRef as? [String] else { return [] }
        return arr
    }

    private func copyChildren(of element: AXUIElement) -> [AXUIElement]? {
        copyElementArrayAttr(of: element, attr: kAXChildrenAttribute as String)
    }

    private func copyElementArrayAttr(of element: AXUIElement, attr: String) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return nil }
        return arr
    }

    private func copyStringArrayAttr(of element: AXUIElement, attr: String) -> [String]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let arr = ref as? [String] else { return nil }
        return arr
    }

    private func copyStringAttr(of element: AXUIElement, attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let ref else { return nil }
        if let str = ref as? String { return str }
        if let attrStr = ref as? NSAttributedString { return attrStr.string }
        return nil
    }

    private func copyBoolAttr(of element: AXUIElement, attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let b = ref as? Bool else { return nil }
        return b
    }

    private func copyPosition(of element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axVal = ref as! AXValue
        var pt = CGPoint.zero
        guard AXValueGetValue(axVal, .cgPoint, &pt) else { return nil }
        return pt
    }

    private func copySize(of element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axVal = ref as! AXValue
        var sz = CGSize.zero
        guard AXValueGetValue(axVal, .cgSize, &sz) else { return nil }
        return sz
    }

    private func collectText(under element: AXUIElement, maxDepth: Int) -> String {
        guard maxDepth >= 0 else { return "" }
        var parts: [String] = []
        for attr in [kAXTitleAttribute as String, kAXValueAttribute as String, kAXDescriptionAttribute as String] {
            if let s = copyStringAttr(of: element, attr: attr), !s.isEmpty {
                parts.append(s)
            }
        }
        if maxDepth > 0, let children = copyChildren(of: element) {
            for c in children {
                let sub = collectText(under: c, maxDepth: maxDepth - 1)
                if !sub.isEmpty { parts.append(sub) }
            }
        }
        return parts.joined(separator: " ")
    }
}

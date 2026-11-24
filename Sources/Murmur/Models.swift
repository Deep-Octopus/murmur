import Carbon
import Foundation
import SwiftUI

struct MonitoredApp: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var displayName: String
    var mainBundleIds: [String]
    var helperBundleIds: [String]
    var dockTileNames: [String]
    var isEnabled: Bool
    var supportsTenantRail: Bool
    var sumsUnreadInDockBadge: Bool
    var isBuiltIn: Bool

    var primaryBundleId: String {
        mainBundleIds.first ?? id
    }

    var allNotificationBundleIds: Set<String> {
        Set(mainBundleIds + helperBundleIds)
    }

    var dockNamesSet: Set<String> {
        Set(dockTileNames + [displayName])
    }

    func matchesBundleId(_ candidate: String) -> Bool {
        let norm = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !norm.isEmpty else { return false }
        if allNotificationBundleIds.contains(norm) { return true }
        let lower = norm.lowercased()
        for bid in mainBundleIds {
            if lower == bid.lowercased() || lower.hasPrefix(bid.lowercased() + ".") || lower.hasPrefix(bid.lowercased() + "-") {
                return true
            }
        }
        return false
    }

    func matchesAppLabel(_ label: String) -> Bool {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if dockNamesSet.contains(clean) { return true }
        let lower = clean.lowercased()
        return dockNamesSet.contains { $0.lowercased() == lower }
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, mainBundleIds, helperBundleIds, dockTileNames, isEnabled, supportsTenantRail, sumsUnreadInDockBadge, isBuiltIn
    }

    init(
        id: String,
        displayName: String,
        mainBundleIds: [String],
        helperBundleIds: [String],
        dockTileNames: [String],
        isEnabled: Bool,
        supportsTenantRail: Bool,
        sumsUnreadInDockBadge: Bool = true,
        isBuiltIn: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.mainBundleIds = mainBundleIds
        self.helperBundleIds = helperBundleIds
        self.dockTileNames = dockTileNames
        self.isEnabled = isEnabled
        self.supportsTenantRail = supportsTenantRail
        self.sumsUnreadInDockBadge = sumsUnreadInDockBadge
        self.isBuiltIn = isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        mainBundleIds = try c.decode([String].self, forKey: .mainBundleIds)
        helperBundleIds = try c.decodeIfPresent([String].self, forKey: .helperBundleIds) ?? []
        dockTileNames = try c.decodeIfPresent([String].self, forKey: .dockTileNames) ?? [displayName]
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        supportsTenantRail = try c.decodeIfPresent(Bool.self, forKey: .supportsTenantRail) ?? false
        sumsUnreadInDockBadge = try c.decodeIfPresent(Bool.self, forKey: .sumsUnreadInDockBadge) ?? (id != "slack" && id != "discord")
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    static let defaultApps: [MonitoredApp] = [
        MonitoredApp(
            id: "feishu",
            displayName: "飞书",
            mainBundleIds: ["com.bytedance.macos.feishu", "com.electron.lark", "com.ss.feishu", "com.larksuite.larkApp"],
            helperBundleIds: ["com.bytedance.macos.feishu-notifier"],
            dockTileNames: ["飞书", "Lark", "Feishu"],
            isEnabled: true,
            supportsTenantRail: true,
            sumsUnreadInDockBadge: true,
            isBuiltIn: true
        ),
        MonitoredApp(
            id: "wechat",
            displayName: "微信",
            mainBundleIds: ["com.tencent.xinWeChat"],
            helperBundleIds: [],
            dockTileNames: ["微信", "WeChat"],
            isEnabled: true,
            supportsTenantRail: false,
            sumsUnreadInDockBadge: true,
            isBuiltIn: true
        ),
        MonitoredApp(
            id: "qq",
            displayName: "QQ",
            mainBundleIds: ["com.tencent.qq", "com.tencent.mqq"],
            helperBundleIds: [],
            dockTileNames: ["QQ"],
            isEnabled: true,
            supportsTenantRail: false,
            sumsUnreadInDockBadge: true,
            isBuiltIn: true
        )
    ]

    static let popularPresets: [MonitoredApp] = [
        MonitoredApp(
            id: "dingtalk",
            displayName: "钉钉",
            mainBundleIds: ["com.alibaba.DingTalkMac"],
            helperBundleIds: [],
            dockTileNames: ["钉钉", "DingTalk"],
            isEnabled: true,
            supportsTenantRail: true,
            sumsUnreadInDockBadge: true,
            isBuiltIn: false
        ),
        MonitoredApp(
            id: "wecom",
            displayName: "企业微信",
            mainBundleIds: ["com.tencent.WeWorkMac"],
            helperBundleIds: [],
            dockTileNames: ["企业微信", "WeCom", "WXWork"],
            isEnabled: true,
            supportsTenantRail: false,
            sumsUnreadInDockBadge: true,
            isBuiltIn: false
        ),
        MonitoredApp(
            id: "slack",
            displayName: "Slack",
            mainBundleIds: ["com.tinyspeck.slackmacgap"],
            helperBundleIds: [],
            dockTileNames: ["Slack"],
            isEnabled: true,
            supportsTenantRail: true,
            sumsUnreadInDockBadge: false,
            isBuiltIn: false
        ),
        MonitoredApp(
            id: "telegram",
            displayName: "Telegram",
            mainBundleIds: ["ru.keepcoder.Telegram", "org.telegram.desktop"],
            helperBundleIds: [],
            dockTileNames: ["Telegram"],
            isEnabled: true,
            supportsTenantRail: false,
            sumsUnreadInDockBadge: true,
            isBuiltIn: false
        ),
        MonitoredApp(
            id: "discord",
            displayName: "Discord",
            mainBundleIds: ["com.hnc.Discord"],
            helperBundleIds: [],
            dockTileNames: ["Discord"],
            isEnabled: true,
            supportsTenantRail: false,
            sumsUnreadInDockBadge: false,
            isBuiltIn: false
        ),
        MonitoredApp(
            id: "mail",
            displayName: "邮件",
            mainBundleIds: ["com.apple.mail"],
            helperBundleIds: [],
            dockTileNames: ["邮件", "Mail"],
            isEnabled: true,
            supportsTenantRail: false,
            sumsUnreadInDockBadge: true,
            isBuiltIn: false
        )
    ]

    static func fromApplicationBundle(url: URL) -> MonitoredApp? {
        guard let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier,
              !bundleId.isEmpty else {
            return nil
        }

        let fileBaseName = url.deletingPathExtension().lastPathComponent
        let info = bundle.infoDictionary ?? [:]
        let localizedInfo = bundle.localizedInfoDictionary ?? [:]

        let dispName = (localizedInfo["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? (localizedInfo["CFBundleName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? fileBaseName

        var names = Set<String>([dispName, fileBaseName])
        if let n1 = info["CFBundleName"] as? String, !n1.isEmpty { names.insert(n1) }
        if let n2 = info["CFBundleDisplayName"] as? String, !n2.isEmpty { names.insert(n2) }

        var helpers: [String] = []
        let frameworksURL = url.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(at: frameworksURL, includingPropertiesForKeys: nil) {
            for sub in items where sub.pathExtension == "app" && sub.lastPathComponent.lowercased().contains("notif") {
                if let subId = Bundle(url: sub)?.bundleIdentifier {
                    helpers.append(subId)
                }
            }
        }

        return MonitoredApp(
            id: bundleId,
            displayName: dispName,
            mainBundleIds: [bundleId],
            helperBundleIds: helpers,
            dockTileNames: Array(names),
            isEnabled: true,
            supportsTenantRail: false,
            sumsUnreadInDockBadge: true,
            isBuiltIn: false
        )
    }
}

enum AgingLevel: Int, Comparable, Codable {
    case fresh = 0
    case warning = 1
    case overdue = 2

    static func < (lhs: AgingLevel, rhs: AgingLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum DockBadgeReading: Equatable {
    case unavailable
    case clear
    case dot
    case count(Int)
    case atLeast(Int)

    var hasUnread: Bool {
        switch self {
        case .dot, .count, .atLeast: return true
        case .unavailable, .clear: return false
        }
    }

    var displayText: String {
        switch self {
        case .unavailable, .clear: return ""
        case .dot: return "有未读"
        case .count(let n): return "\(n)"
        case .atLeast(let n): return "\(n)+"
        }
    }
}

enum ConversationAttentionKind: String, Codable, Equatable {
    case directOrUnmuted
    case mentionedInMuted
    case mutedNoise
}

struct ConversationSnapshot: Equatable {
    let appId: String
    let tenantName: String?
    let title: String
    let preview: String
    let badgeText: String
    let hasStandaloneNumericBadge: Bool
    let hasExplicitMuteSignal: Bool
    let hasMentionBreakthrough: Bool
    let pid: pid_t

    var badgeIntValue: Int? {
        let digits = badgeText.filter { $0.isNumber }
        guard let val = Int(digits), val > 0 else { return nil }
        return val
    }
}

struct TenantBadgeHint: Equatable, Identifiable {
    var id: String { "\(appId)|\(tenantName)" }
    let appId: String
    let tenantName: String
    let badgeText: String
    let isDotOnly: Bool
    let isSelected: Bool
}

enum EntrySourceKind: String, Codable {
    case notification
    case sidebarSnapshot
    case tenantHint
    case dockHint
    case demo
}

struct MutedConversationRule: Identifiable, Codable, Equatable {
    var id: String { "\(appId)|\(sender)" }
    let appId: String
    let appName: String
    let sender: String
}

struct MessageItem: Identifiable, Equatable, Codable {
    let id: String
    let appId: String
    let bundleId: String
    var tenantName: String?
    var sender: String
    var subtitle: String
    var body: String
    var unreadBadgeText: String?
    var hasMentionBreakthrough: Bool
    let firstObservedAt: Date
    var latestActivityAt: Date
    var isTimestampExact: Bool
    var snoozedUntil: Date?
    var sourceKind: EntrySourceKind
    var lastNotifiedOverdueAt: Date?
    var contentRevision: String

    enum CodingKeys: String, CodingKey {
        case id, appId, bundleId, tenantName, sender, subtitle, body, unreadBadgeText, hasMentionBreakthrough
        case firstObservedAt, latestActivityAt, isTimestampExact, snoozedUntil, sourceKind, lastNotifiedOverdueAt, contentRevision
    }

    init(
        id: String,
        appId: String,
        bundleId: String,
        tenantName: String?,
        sender: String,
        subtitle: String,
        body: String,
        unreadBadgeText: String?,
        hasMentionBreakthrough: Bool = false,
        firstObservedAt: Date,
        latestActivityAt: Date,
        isTimestampExact: Bool,
        snoozedUntil: Date?,
        sourceKind: EntrySourceKind,
        lastNotifiedOverdueAt: Date?,
        contentRevision: String
    ) {
        self.id = id
        self.appId = appId
        self.bundleId = bundleId
        self.tenantName = tenantName
        self.sender = sender
        self.subtitle = subtitle
        self.body = body
        self.unreadBadgeText = unreadBadgeText
        self.hasMentionBreakthrough = hasMentionBreakthrough
        self.firstObservedAt = firstObservedAt
        self.latestActivityAt = latestActivityAt
        self.isTimestampExact = isTimestampExact
        self.snoozedUntil = snoozedUntil
        self.sourceKind = sourceKind
        self.lastNotifiedOverdueAt = lastNotifiedOverdueAt
        self.contentRevision = contentRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        appId = try c.decode(String.self, forKey: .appId)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        tenantName = try c.decodeIfPresent(String.self, forKey: .tenantName)
        sender = try c.decode(String.self, forKey: .sender)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        body = try c.decode(String.self, forKey: .body)
        unreadBadgeText = try c.decodeIfPresent(String.self, forKey: .unreadBadgeText)
        hasMentionBreakthrough = try c.decodeIfPresent(Bool.self, forKey: .hasMentionBreakthrough) ?? false
        firstObservedAt = try c.decode(Date.self, forKey: .firstObservedAt)
        latestActivityAt = try c.decode(Date.self, forKey: .latestActivityAt)
        isTimestampExact = try c.decodeIfPresent(Bool.self, forKey: .isTimestampExact) ?? false
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        sourceKind = try c.decode(EntrySourceKind.self, forKey: .sourceKind)
        lastNotifiedOverdueAt = try c.decodeIfPresent(Date.self, forKey: .lastNotifiedOverdueAt)
        contentRevision = try c.decode(String.self, forKey: .contentRevision)
    }

    func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return now < snoozedUntil
    }

    func waitedMinutes(at now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(firstObservedAt) / 60.0))
    }

    func agingLevel(at now: Date, warningMinutes: Int, overdueMinutes: Int) -> AgingLevel {
        if isSnoozed(at: now) { return .fresh }
        let mins = waitedMinutes(at: now)
        if mins >= overdueMinutes { return .overdue }
        if mins >= warningMinutes { return .warning }
        return .fresh
    }

    func ageLabel(at now: Date, overdueMinutes: Int) -> String {
        if let snoozedUntil, now < snoozedUntil {
            let left = max(1, Int(ceil(snoozedUntil.timeIntervalSince(now) / 60.0)))
            if left >= 60 {
                return "稍后 \(left / 60)h"
            }
            return "稍后 \(left)m"
        }
        let secs = max(0, Int(now.timeIntervalSince(firstObservedAt)))
        if secs < 60 {
            return isTimestampExact ? "刚刚" : "刚发现"
        }
        let mins = secs / 60
        let core: String
        if mins < 60 {
            core = "\(mins)m"
        } else {
            let h = mins / 60
            let r = mins % 60
            core = r > 0 ? "\(h)h\(r)m" : "\(h)h"
        }
        if mins >= overdueMinutes {
            return isTimestampExact ? "已等 \(core)" : "发现 \(core)"
        }
        return core
    }
}

enum HotKeyPreset: String, CaseIterable, Identifiable, Codable {
    case optionM = "optionM"
    case optionSpace = "optionSpace"
    case ctrlOptionM = "ctrlOptionM"
    case cmdShiftM = "cmdShiftM"

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .optionM: return "⌥ + M"
        case .optionSpace: return "⌥ + Space"
        case .ctrlOptionM: return "⌃ + ⌥ + M"
        case .cmdShiftM: return "⌘ + ⇧ + M"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .optionSpace: return UInt32(kVK_Space)
        case .optionM, .ctrlOptionM, .cmdShiftM: return UInt32(kVK_ANSI_M)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .optionM, .optionSpace: return UInt32(optionKey)
        case .ctrlOptionM: return UInt32(controlKey | optionKey)
        case .cmdShiftM: return UInt32(cmdKey | shiftKey)
        }
    }
}

enum PeekPayload: Equatable {
    case incoming(MessageItem)
    case overdueDigest(count: Int, oldestMinutes: Int, oldestItem: MessageItem)
}

enum SurfaceMode: Equatable {
    case compact
    case peek(PeekPayload)
    case expanded
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色纸感"
        case .dark: return "深色石墨"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum WindowLevelMode: String, CaseIterable, Identifiable {
    case alwaysOnTop = "alwaysOnTop"
    case desktopFloating = "desktopFloating"
    case normal = "normal"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysOnTop: return "全局最顶层"
        case .desktopFloating: return "普通置顶"
        case .normal: return "不置顶"
        }
    }

    var subtitle: String {
        switch self {
        case .alwaysOnTop: return "跨空间浮在所有窗口及全屏应用之上"
        case .desktopFloating: return "日常桌面置顶，全屏演示/视频时自动避让"
        case .normal: return "普通窗口层级，点击其他软件可自然遮盖"
        }
    }
}

enum ScreenCorner: String, CaseIterable, Identifiable {
    case topRight = "右上角"
    case bottomRight = "右下角"
    case topLeft = "左上角"
    case bottomLeft = "左下角"

    var id: String { rawValue }
}

enum JumpOutcome: Equatable {
    case conversationOpened
    case tenantSwitched(String)
    case appActivatedNeedsConfirm
    case appLaunched

    var resolvedConversationDirectly: Bool {
        if case .conversationOpened = self { return true }
        return false
    }

    func feedbackText(appName: String) -> String {
        switch self {
        case .conversationOpened:
            return "已定位到\(appName)对应会话"
        case .tenantSwitched(let tenant):
            return "已切换至\(appName) · \(tenant)"
        case .appActivatedNeedsConfirm:
            return "已打开\(appName)，处理后可点 ✓（读完也会自动消隐）"
        case .appLaunched:
            return "正在启动\(appName)..."
        }
    }
}

import AppKit
import SwiftUI

struct OrbRootView: View {
    @ObservedObject var store: MessageStore
    @Environment(\.colorScheme) private var systemColorScheme

    private var effectiveIsDark: Bool {
        switch store.appearanceMode {
        case .system: return systemColorScheme == .dark
        case .dark: return true
        case .light: return false
        }
    }

    var body: some View {
        let palette = Palette(isDark: effectiveIsDark)

        Group {
            switch store.surfaceMode {
            case .compact:
                CompactPillSurface(store: store, palette: palette)
            case .peek(let payload):
                PeekSurface(store: store, payload: payload, palette: palette)
            case .expanded:
                ExpandedQueueSurface(store: store, palette: palette)
            }
        }
        .padding(8)
        .fixedSize()
        .preferredColorScheme(store.appearanceMode.preferredColorScheme)
    }
}

// MARK: - 1. Quiet, Tactile Single Compact Surface

struct CompactPillSurface: View {
    @ObservedObject var store: MessageStore
    let palette: Palette

    var body: some View {
        let count = store.pendingItemCount
        let hasPresenceOnly = store.hasUnresolvedAggregatePresence
        let scale = CGFloat(min(max(store.orbScale, 0.8), 1.75))
        let level = store.oldestAgingLevel
        let height = round(36 * scale)
        let isIdle = (count == 0 && !hasPresenceOnly)

        Button {
            store.toggleExpanded()
        } label: {
            HStack(spacing: round(6.5 * scale)) {
                statusDot(isIdle: isIdle, level: level, scale: scale)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: round(13 * scale), weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(palette.primaryInk)

                    let activeApps = store.enabledApps.filter { store.pendingCountForApp($0.id) > 0 }.prefix(4)
                    if !activeApps.isEmpty {
                        HStack(spacing: round(3.5 * scale)) {
                            ForEach(Array(activeApps)) { app in
                                AppIconView(app: app, size: round(15 * scale))
                            }
                        }
                    }
                } else if hasPresenceOnly {
                    Text("有未读")
                        .font(.system(size: round(11.5 * scale), weight: .medium))
                        .foregroundStyle(palette.secondaryInk)
                }
            }
            .padding(.horizontal, isIdle ? 0 : round(11 * scale))
            .frame(minWidth: height, minHeight: height)
            .background(
                Capsule(style: .continuous)
                    .fill(palette.surfaceFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                store.isOrbHovering ? palette.primaryInk.opacity(0.26) : palette.hairlineBorder,
                                lineWidth: 1.0
                            )
                    )
            )
            .clipShape(Capsule(style: .continuous))
            .scaleEffect(store.isOrbPressed ? 0.96 : 1.0)
            .opacity((isIdle && !store.isOrbHovering) ? store.idleOpacity : 1.0)
            .shadow(color: .black.opacity(palette.isDark ? 0.30 : 0.14), radius: 7, x: 0, y: 2)
            .animation(.easeOut(duration: 0.10), value: store.isOrbHovering)
            .animation(.easeOut(duration: 0.07), value: store.isOrbPressed)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            store.isOrbHovering = hovering
        }
    }

    @ViewBuilder
    private func statusDot(isIdle: Bool, level: AgingLevel, scale: CGFloat) -> some View {
        if store.isPeeksPaused {
            Image(systemName: "moon.fill")
                .font(.system(size: round(9.5 * scale)))
                .foregroundStyle(palette.tertiaryInk)
        } else if isIdle {
            Circle()
                .fill(palette.tertiaryInk.opacity(0.68))
                .frame(width: round(8 * scale), height: round(8 * scale))
        } else {
            switch level {
            case .overdue:
                Image(systemName: "clock.fill")
                    .font(.system(size: round(10.5 * scale), weight: .semibold))
                    .foregroundStyle(palette.overdueAccent)
            case .warning:
                Circle()
                    .fill(palette.warmAccent)
                    .frame(width: round(7.5 * scale), height: round(7.5 * scale))
            case .fresh:
                Circle()
                    .fill(palette.calmAccent)
                    .frame(width: round(7.5 * scale), height: round(7.5 * scale))
            }
        }
    }
}

// MARK: - 2. Single Cohesive Peek Surface

struct PeekSurface: View {
    @ObservedObject var store: MessageStore
    let payload: PeekPayload
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch payload {
            case .incoming(let item):
                let appObj = store.app(for: item.appId)
                let itemLevel = item.agingLevel(
                    at: store.now,
                    warningMinutes: store.warningMinutes,
                    overdueMinutes: store.overdueMinutes
                )
                HStack(alignment: .center, spacing: 11) {
                    AppIconView(app: appObj, size: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(item.sender)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(palette.primaryInk)
                                .lineLimit(1)

                            if item.hasMentionBreakthrough {
                                MentionTagView(palette: palette)
                            } else if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.tertiaryInk)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            AgeBadgeView(
                                label: item.ageLabel(at: store.now, overdueMinutes: store.overdueMinutes),
                                level: itemLevel,
                                palette: palette
                            )
                        }

                        Text(item.body)
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryInk)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 4) {
                        IconActionButton(systemName: "checkmark", helpText: "标记已完成", palette: palette) {
                            store.completeItem(item)
                        }
                        IconActionButton(systemName: "xmark", helpText: "收起提示", palette: palette) {
                            store.dismissPeek()
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.handleRowTap(item)
                }

            case .overdueDigest(let count, let oldestMinutes, let oldestItem):
                let appObj = store.app(for: oldestItem.appId)
                HStack(alignment: .center, spacing: 11) {
                    AppIconView(app: appObj, size: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.overdueAccent)

                            Text(count > 1 ? "\(count) 项等待处理" : oldestItem.sender)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(palette.primaryInk)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            Text("最久 \(oldestMinutes)m")
                                .font(.system(size: 11.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(palette.overdueAccent)
                        }

                        Text(count > 1 ? "最早：\(oldestItem.sender) — \(oldestItem.body)" : oldestItem.body)
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryInk)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 4) {
                        IconActionButton(systemName: "list.bullet", helpText: "展开全部", palette: palette) {
                            store.toggleExpanded()
                        }
                        IconActionButton(systemName: "xmark", helpText: "收起", palette: palette) {
                            store.dismissPeek()
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.handleRowTap(oldestItem)
                }
            }
        }
        .frame(width: 336)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.surfaceFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.hairlineBorder, lineWidth: 1.0)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(palette.isDark ? 0.34 : 0.15), radius: 10, x: 0, y: 3)
        .onHover { hovering in
            store.setPeekHovering(hovering)
        }
    }
}

// MARK: - 3. Clean Chronological Queue & Extensible Settings Surface

struct ExpandedQueueSurface: View {
    @ObservedObject var store: MessageStore
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactHeader
                .padding(.horizontal, 13)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Rectangle()
                .fill(palette.dividerColor)
                .frame(height: 1)

            if store.showSettings {
                settingsBody
                    .padding(14)
            } else {
                queueBody
            }

            if store.undoBanner != nil || store.transientNotice != nil {
                Rectangle()
                    .fill(palette.dividerColor)
                    .frame(height: 1)
                feedbackFooter
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 374)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.surfaceFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.hairlineBorder, lineWidth: 1.0)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(palette.isDark ? 0.38 : 0.16), radius: 12, x: 0, y: 4)
    }

    private var compactHeader: some View {
        HStack(spacing: 5) {
            if store.showSettings {
                Button {
                    store.showSettings = false
                    store.onLayoutNeedsUpdate?(true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("返回待处理")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(palette.primaryInk)
                }
                .buttonStyle(.plain)

                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    filterStrip
                }

                Spacer(minLength: 2)

                let snoozedCount = store.snoozedItems.count
                if snoozedCount > 0 || store.showSnoozedSheet {
                    Button {
                        store.showSnoozedSheet.toggle()
                        store.onLayoutNeedsUpdate?(true)
                    } label: {
                        Text(store.showSnoozedSheet ? "待办" : "稍后\(snoozedCount)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(store.showSnoozedSheet ? palette.calmAccent : palette.secondaryInk)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(palette.subtleControlFill))
                    }
                    .buttonStyle(.plain)
                }

                if store.displayedQueueItems.count >= 2 && !store.showSnoozedSheet {
                    IconActionButton(
                        systemName: "checkmark.circle",
                        helpText: "当前列表全部标为已阅（5秒内可 ⌘Z 撤销）",
                        palette: palette
                    ) {
                        store.clearVisibleCompleted()
                    }
                }

                IconActionButton(
                    systemName: store.sortOldestFirst ? "arrow.down" : "arrow.up",
                    helpText: store.sortOldestFirst ? "等待最久在前（点击切最新在前）" : "最新消息在前（点击切最久在前）",
                    palette: palette
                ) {
                    store.sortOldestFirst.toggle()
                }
            }

            IconActionButton(
                systemName: store.isPinnedExpanded ? "pin.fill" : "pin",
                helpText: store.isPinnedExpanded ? "已固定常驻（点击取消固定）" : "固定面板（点击外部或跳转后保持展开）",
                isActive: store.isPinnedExpanded,
                palette: palette
            ) {
                store.isPinnedExpanded.toggle()
            }

            IconActionButton(
                systemName: "slider.horizontal.3",
                helpText: "监控软件与偏好设置",
                isActive: store.showSettings,
                palette: palette
            ) {
                store.showSettings.toggle()
                store.onLayoutNeedsUpdate?(true)
            }

            IconActionButton(
                systemName: "chevron.up",
                helpText: "收起面板 (Esc / \(store.hotKeyPreset.displayLabel))",
                palette: palette
            ) {
                store.collapsePanel()
            }
        }
    }

    private var filterStrip: some View {
        HStack(spacing: 3.5) {
            QuietFilterButton(
                app: nil,
                label: "待处理",
                count: store.pendingItemCount,
                selected: store.selectedFilterAppId == nil && !store.showSnoozedSheet,
                palette: palette
            ) {
                store.showSnoozedSheet = false
                store.selectedFilterAppId = nil
                store.onLayoutNeedsUpdate?(true)
            }

            ForEach(store.enabledApps) { app in
                let cnt = store.pendingCountForApp(app.id)
                QuietFilterButton(
                    app: app,
                    label: nil,
                    count: cnt,
                    selected: store.selectedFilterAppId == app.id,
                    palette: palette
                ) {
                    store.showSnoozedSheet = false
                    store.selectedFilterAppId = (store.selectedFilterAppId == app.id) ? nil : app.id
                    store.onLayoutNeedsUpdate?(true)
                }
            }

            Button {
                store.showSettings = true
                store.settingsTab = 0
                store.onLayoutNeedsUpdate?(true)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.tertiaryInk)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(palette.subtleControlFill.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .help("添加或管理监控软件")
        }
    }

    // MARK: - Queue Body + Quiet Muted Chats Disclosure Drawer

    @ViewBuilder
    private var queueBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.hasAccessibilityPermission && !store.dismissedSetupHint {
                HStack(spacing: 6) {
                    Text("需开启「辅助功能」以读取会话列表与实时通知")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryInk)
                        .lineLimit(1)
                    Spacer()
                    Button("去开启") {
                        AccessibilityBridge.openAccessibilitySettings()
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.calmAccent)
                    .buttonStyle(.plain)

                    Button {
                        store.dismissedSetupHint = true
                        store.onLayoutNeedsUpdate?(true)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(palette.tertiaryInk)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(palette.subtleControlFill.opacity(0.6))

                Rectangle()
                    .fill(palette.dividerColor)
                    .frame(height: 1)
            }

            let list = store.displayedQueueItems
            if list.isEmpty {
                calmEmptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { idx, item in
                                ConversationRowView(
                                    store: store,
                                    item: item,
                                    isKeyboardSelected: idx == store.selectedKeyboardIndex,
                                    palette: palette
                                )
                                .id(item.id)

                                if idx < list.count - 1 {
                                    Rectangle()
                                        .fill(palette.dividerColor)
                                        .frame(height: 1)
                                        .padding(.leading, 48)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 356)
                    .onChange(of: store.selectedKeyboardIndex) { _, newIdx in
                        let currentList = store.displayedQueueItems
                        if newIdx >= 0 && newIdx < currentList.count {
                            withAnimation(.easeOut(duration: 0.14)) {
                                proxy.scrollTo(currentList[newIdx].id, anchor: nil)
                            }
                        }
                    }
                }
            }

            let mutedList = store.displayedSuppressedMutedItems
            if !mutedList.isEmpty {
                Rectangle()
                    .fill(palette.dividerColor)
                    .frame(height: 1)

                mutedDisclosureSection(mutedList: mutedList)
            }
        }
    }

    @ViewBuilder
    private func mutedDisclosureSection(mutedList: [MessageItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.showMutedDrawer.toggle()
                store.onLayoutNeedsUpdate?(true)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.tertiaryInk)

                    Text("已静默折叠 \(mutedList.count) 个免打扰会话（有人 @我 时自动提至上方）")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryInk)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Image(systemName: store.showMutedDrawer ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(palette.tertiaryInk)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.showMutedDrawer {
                Rectangle()
                    .fill(palette.dividerColor.opacity(0.65))
                    .frame(height: 1)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(mutedList.enumerated()), id: \.element.id) { idx, mItem in
                            MutedConversationRowView(store: store, item: mItem, palette: palette)
                            if idx < mutedList.count - 1 {
                                Rectangle()
                                    .fill(palette.dividerColor.opacity(0.5))
                                    .frame(height: 1)
                                    .padding(.leading, 40)
                            }
                        }
                    }
                }
                .frame(maxHeight: 148)
                .background(palette.subtleControlFill.opacity(0.32))
            }
        }
    }

    private var calmEmptyState: some View {
        VStack(spacing: 8) {
            if store.showSnoozedSheet {
                Text("没有稍后提醒项")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondaryInk)
            } else if let filterId = store.selectedFilterAppId {
                let targetApp = store.app(for: filterId)
                Text("\(targetApp.displayName) 当前没有待处理消息")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondaryInk)

                Text("新通知横幅与未读状态实时同步中，免打扰闲聊已自动静默")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.tertiaryInk)
                    .multilineTextAlignment(.center)

                Button("打开\(targetApp.displayName) ↗") {
                    store.onOpenAppRequested?(targetApp)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.calmAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(palette.subtleControlFill))
                .buttonStyle(.plain)
            } else {
                Text("当前没有待处理项")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondaryInk)

                if store.hasUnresolvedAggregatePresence {
                    Text("Dock 角标显示有未读，展开对应软件窗口后可自动定位会话")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.tertiaryInk)
                        .multilineTextAlignment(.center)
                } else {
                    Text("按等待时间顺序守护重要消息 · 空格可预览长文 · ⏎ 直达会话")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryInk)
                        .multilineTextAlignment(.center)

                    Button("载入示例体验") {
                        store.injectDemoSample()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryInk)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(palette.subtleControlFill))
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
    }

    private var feedbackFooter: some View {
        HStack(spacing: 8) {
            if let undo = store.undoBanner {
                Text(undo.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryInk)
                    .lineLimit(1)
                Spacer()
                Button("撤销 (⌘Z)") {
                    store.undoLastAction()
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.calmAccent)
                .buttonStyle(.plain)
            } else if let notice = store.transientNotice {
                Text(notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryInk)
                    .lineLimit(1)
                Spacer()
            }
        }
    }

    // MARK: - 3-Tab Complete Settings (0: 监控软件, 1: 外观·热键, 2: 降噪·提醒)

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 5) {
                tabPill("监控软件", index: 0)
                tabPill("外观·热键", index: 1)
                tabPill("降噪·提醒", index: 2)
            }

            if store.settingsTab == 0 {
                monitoredAppsTab
            } else if store.settingsTab == 1 {
                appearanceAndWindowTab
            } else {
                rulesAndMuteTab
            }
        }
    }

    private func tabPill(_ title: String, index: Int) -> some View {
        let active = (store.settingsTab == index)
        return Button {
            store.settingsTab = index
            store.onLayoutNeedsUpdate?(true)
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? palette.primaryInk : palette.secondaryInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? palette.subtleControlFill.opacity(1.8) : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(active ? palette.hairlineBorder : .clear, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 0: Dynamic App Manager (`+ 选择应用` & Popular Presets)

    private var monitoredAppsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已接入软件")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.secondaryInk)
                Spacer()
                Button {
                    if let picked = AppPickerHelper.pickApplicationFromDisk(store: store) {
                        store.addOrEnableApp(picked)
                    }
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("从应用程序选择...")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(palette.calmAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(palette.subtleControlFill))
                }
                .buttonStyle(.plain)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(store.monitoredApps) { app in
                        HStack(spacing: 9) {
                            AppIconView(app: app, size: 20)
                                .opacity(app.isEnabled ? 1.0 : 0.45)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.displayName)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(app.isEnabled ? palette.primaryInk : palette.tertiaryInk)
                                Text(app.primaryBundleId)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(palette.tertiaryInk)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if !app.isBuiltIn {
                                Button {
                                    store.removeCustomApp(app.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(palette.tertiaryInk)
                                }
                                .buttonStyle(.plain)
                                .help("移除该软件")
                            }

                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { app.isEnabled },
                                    set: { _ in store.toggleAppEnabled(app.id) }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(palette.subtleControlFill.opacity(0.65))
                        )
                    }
                }
            }
            .frame(maxHeight: 175)

            let existingIds = Set(store.monitoredApps.flatMap(\.mainBundleIds))
            let availablePresets = MonitoredApp.popularPresets.filter { preset in
                Set(preset.mainBundleIds).isDisjoint(with: existingIds)
            }

            if !availablePresets.isEmpty {
                Rectangle().fill(palette.dividerColor).frame(height: 1)

                VStack(alignment: .leading, spacing: 5) {
                    Text("常用软件一键添加")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.tertiaryInk)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(availablePresets) { preset in
                                Button {
                                    store.addOrEnableApp(preset)
                                } label: {
                                    HStack(spacing: 4) {
                                        AppIconView(app: preset, size: 14)
                                        Text("+ \(preset.displayName)")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(palette.primaryInk)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(palette.subtleControlFill))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tab 1: Appearance, Zero-Pixel Zen Mode, Hotkey & Launch at Login

    private var orbScaleBinding: Binding<Double> {
        Binding<Double>(
            get: { store.orbScale },
            set: { val in
                store.orbScale = val
                store.onLayoutNeedsUpdate?(false)
            }
        )
    }

    private var appearanceAndWindowTab: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                Text("外观色调")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.secondaryInk)

                HStack(spacing: 6) {
                    ForEach(AppearanceMode.allCases) { mode in
                        let sel = (store.appearanceMode == mode)
                        Button {
                            store.appearanceMode = mode
                        } label: {
                            Text(mode.displayName)
                                .font(.system(size: 11.5, weight: sel ? .semibold : .regular))
                                .foregroundStyle(sel ? palette.primaryInk : palette.secondaryInk)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(sel ? palette.subtleControlFill.opacity(1.8) : palette.subtleControlFill.opacity(0.6))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("置顶层级")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.secondaryInk)

                HStack(spacing: 6) {
                    ForEach(WindowLevelMode.allCases) { mode in
                        let sel = (store.windowLevelMode == mode)
                        Button {
                            store.windowLevelMode = mode
                        } label: {
                            Text(mode.displayName)
                                .font(.system(size: 11.5, weight: sel ? .semibold : .regular))
                                .foregroundStyle(sel ? palette.primaryInk : palette.secondaryInk)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(sel ? palette.subtleControlFill.opacity(1.8) : palette.subtleControlFill.opacity(0.6))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(spacing: 4) {
                HStack {
                    Text("悬浮球尺寸")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.primaryInk)
                    Spacer()
                    Text("\(Int(round(store.orbScale * 100.0)))%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondaryInk)
                }
                Slider(value: orbScaleBinding, in: 0.80...1.65)

                HStack {
                    Text("静默透明度")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.primaryInk)
                    Spacer()
                    Text("\(Int(round(store.idleOpacity * 100.0)))%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondaryInk)
                }
                Slider(value: $store.idleOpacity, in: 0.30...1.0)
            }

            Rectangle().fill(palette.dividerColor).frame(height: 1)

            Toggle(
                "无待办时自动隐藏桌面胶囊（仅保留顶部菜单栏图标）",
                isOn: Binding(
                    get: { store.hideOrbWhenIdle },
                    set: { store.setHideOrbWhenIdle($0) }
                )
            )
            .font(.system(size: 11.5))
            .toggleStyle(.switch)
            .controlSize(.mini)

            HStack(spacing: 8) {
                Toggle(
                    "全局呼出热键",
                    isOn: Binding(
                        get: { store.enableGlobalHotkey },
                        set: { val in
                            store.enableGlobalHotkey = val
                            store.onHotkeySettingChanged?(val)
                        }
                    )
                )
                .font(.system(size: 11.5))
                .toggleStyle(.switch)
                .controlSize(.mini)

                Spacer()

                Picker(
                    "",
                    selection: Binding(
                        get: { store.hotKeyPreset },
                        set: { store.hotKeyPreset = $0 }
                    )
                ) {
                    ForEach(HotKeyPreset.allCases) { preset in
                        Text(preset.displayLabel).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
                .disabled(!store.enableGlobalHotkey)
            }

            if store.hotKeyConflictError {
                Text("⚠️ 当前快捷键已被其他软件占用，建议切换为 ⌃+⌥+M")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.overdueAccent)
            }

            HStack {
                Toggle("锁定拖动位置（按住 ⌥ 拖动）", isOn: $store.lockOrbPosition)
                    .font(.system(size: 11.5))
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                Spacer()

                Toggle(
                    "开机自启",
                    isOn: Binding(
                        get: { store.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    )
                )
                .font(.system(size: 11.5))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            HStack(spacing: 6) {
                Text("停靠当前屏:")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryInk)
                ForEach(ScreenCorner.allCases) { corner in
                    Button(corner.rawValue) {
                        store.onSnapCornerRequested?(corner)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.primaryInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.subtleControlFill))
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Tab 2: Smart Muted Filtering, Escalation Timers & Block Rules

    private var rulesAndMuteTab: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Toggle(
                    "智能过滤「消息免打扰」群（保留 @我 / @所有人 破圈提醒）",
                    isOn: Binding(
                        get: { store.autoFilterMutedChats },
                        set: { store.setAutoFilterMutedChats($0) }
                    )
                )
                .font(.system(size: 11.5, weight: .medium))
                .toggleStyle(.switch)
                .controlSize(.mini)

                Text("结合静音标识与 Dock 真实未读数自动折叠免打扰群，列表底部可随时展开查看")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.tertiaryInk)
            }

            Rectangle().fill(palette.dividerColor).frame(height: 1)

            HStack {
                Text("温和变色提醒")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.primaryInk)
                Spacer()
                Picker("", selection: $store.warningMinutes) {
                    Text("3 分钟").tag(3)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                }
                .labelsHidden()
                .frame(width: 90)
            }

            HStack {
                Text("超时提醒阈值")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.primaryInk)
                Spacer()
                Picker("", selection: $store.overdueMinutes) {
                    Text("5 分钟").tag(5)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                }
                .labelsHidden()
                .frame(width: 90)
            }

            HStack {
                Text("会议免弹窗模式")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.primaryInk)
                Spacer()
                if store.isPeeksPaused {
                    Button("恢复提醒") {
                        store.pausePeeks(minutes: 0)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.calmAccent)
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 5) {
                        Button("暂停30m") { store.pausePeeks(minutes: 30) }
                            .font(.system(size: 11))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(palette.subtleControlFill))
                            .buttonStyle(.plain)
                        Button("暂停1h") { store.pausePeeks(minutes: 60) }
                            .font(.system(size: 11))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(palette.subtleControlFill))
                            .buttonStyle(.plain)
                    }
                }
            }

            Rectangle().fill(palette.dividerColor).frame(height: 1)

            VStack(alignment: .leading, spacing: 5) {
                Text("永久屏蔽名单（右键任意会话可添加）")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryInk)

                if store.mutedRules.isEmpty {
                    Text("暂无手动屏蔽会话")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryInk)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 4) {
                            ForEach(store.mutedRules) { rule in
                                HStack {
                                    Text("[\(rule.appName)] \(rule.sender)")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(palette.primaryInk)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("恢复") {
                                        store.removeMutedRule(rule)
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(palette.calmAccent)
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(palette.subtleControlFill))
                            }
                        }
                    }
                    .frame(maxHeight: 78)
                }
            }

            Rectangle().fill(palette.dividerColor).frame(height: 1)

            HStack(spacing: 10) {
                Button("载入示例") {
                    store.showSettings = false
                    store.injectDemoSample()
                }
                .font(.system(size: 11.5))
                .foregroundStyle(palette.secondaryInk)
                .buttonStyle(.plain)

                if !store.items.isEmpty {
                    Button("全部标已阅") {
                        store.clearVisibleCompleted()
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryInk)
                    .buttonStyle(.plain)
                }

                Spacer()

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.overdueAccent)
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 4. Conversation Row (2-Line Default + Space 8-Line Expand + @提及 Tag)

struct ConversationRowView: View {
    @ObservedObject var store: MessageStore
    let item: MessageItem
    let isKeyboardSelected: Bool
    let palette: Palette

    var body: some View {
        let appObj = store.app(for: item.appId)
        let hovering = (store.hoveredRowId == item.id)
        let isBodyExpanded = (store.expandedBodyItemId == item.id)
        let level = item.agingLevel(
            at: store.now,
            warningMinutes: store.warningMinutes,
            overdueMinutes: store.overdueMinutes
        )

        HStack(alignment: .top, spacing: 11) {
            AppIconView(app: appObj, size: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(item.sender)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.primaryInk)
                        .lineLimit(1)

                    if item.hasMentionBreakthrough {
                        MentionTagView(palette: palette)
                    }

                    if !item.subtitle.isEmpty {
                        Text("· \(item.subtitle)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.tertiaryInk)
                            .lineLimit(1)
                    } else if let cnt = item.unreadBadgeText, cnt != "1", cnt != "有未读" {
                        Text("· \(cnt)条")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(palette.tertiaryInk)
                    }

                    Spacer(minLength: 4)

                    if hovering {
                        HStack(spacing: 4) {
                            if item.body.count > 26 {
                                IconActionButton(
                                    systemName: isBodyExpanded ? "chevron.up.circle" : "text.magnifyingglass",
                                    helpText: isBodyExpanded ? "收起长消息 (Space)" : "展开完整消息 (Space)",
                                    palette: palette
                                ) {
                                    store.toggleExpandedBody(for: item.id)
                                }
                            }
                            IconActionButton(systemName: "clock", helpText: "稍后 15 分钟提醒 (S)", palette: palette) {
                                store.snooze(item, minutes: 15)
                            }
                            IconActionButton(systemName: "checkmark", helpText: "标记已完成 (⌫)", palette: palette) {
                                store.completeItem(item)
                            }
                        }
                    } else {
                        AgeBadgeView(
                            label: item.ageLabel(at: store.now, overdueMinutes: store.overdueMinutes),
                            level: level,
                            palette: palette
                        )
                    }
                }

                Text(item.body)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryInk)
                    .lineLimit(isBodyExpanded ? 8 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(item.body)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9.5)
        .frame(minHeight: 56)
        .background(
            (hovering || isKeyboardSelected) ? palette.rowHoverFill : Color.clear
        )
        .overlay(alignment: .leading) {
            if level == .overdue {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(palette.overdueAccent)
                    .frame(width: 2.5, height: 26)
                    .padding(.leading, 3)
            } else if isKeyboardSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(palette.calmAccent.opacity(0.65))
                    .frame(width: 2.5, height: 22)
                    .padding(.leading, 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHover in
            if isHover {
                store.hoveredRowId = item.id
            } else if store.hoveredRowId == item.id {
                store.hoveredRowId = nil
            }
        }
        .onTapGesture {
            store.handleRowTap(item)
        }
        .contextMenu {
            Button("直达该会话 (⏎)") {
                store.handleRowTap(item)
            }
            Button("标记已完成 (⌫)") {
                store.completeItem(item)
            }
            Button(isBodyExpanded ? "收起完整消息 (Space)" : "展开完整消息 (Space)") {
                store.toggleExpandedBody(for: item.id)
            }
            Divider()
            Button("稍后 15 分钟提醒 (S)") {
                store.snooze(item, minutes: 15)
            }
            Button("稍后 1 小时提醒") {
                store.snooze(item, minutes: 60)
            }
            Button("稍后 3 小时提醒") {
                store.snooze(item, minutes: 180)
            }
            Button("明天上午 09:30 提醒") {
                store.snoozeUntilTomorrowMorning(item)
            }
            Divider()
            Button("永久屏蔽「\(item.sender)」") {
                store.muteConversation(item)
            }
        }
    }
}

// MARK: - 5. Quiet Folded Muted Row (Inside Disclosure Drawer)

struct MutedConversationRowView: View {
    @ObservedObject var store: MessageStore
    let item: MessageItem
    let palette: Palette

    var body: some View {
        let appObj = store.app(for: item.appId)
        let hovering = (store.hoveredRowId == item.id)

        HStack(spacing: 9) {
            AppIconView(app: appObj, size: 17)
                .opacity(0.65)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    Text(item.sender)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondaryInk)
                        .lineLimit(1)

                    if let cnt = item.unreadBadgeText {
                        Text("[\(cnt)条]")
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(palette.tertiaryInk)
                    }

                    Spacer()
                }

                Text(item.body)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiaryInk)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6.5)
        .background(hovering ? palette.rowHoverFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHover in
            if isHover {
                store.hoveredRowId = item.id
            } else if store.hoveredRowId == item.id {
                store.hoveredRowId = nil
            }
        }
        .onTapGesture {
            store.handleRowTap(item)
        }
        .contextMenu {
            Button("打开查看该免打扰会话") {
                store.handleRowTap(item)
            }
            Button("永久屏蔽「\(item.sender)」（不再统计）") {
                store.muteConversation(item)
            }
        }
    }
}

// MARK: - Micro Components

struct MentionTagView: View {
    let palette: Palette

    var body: some View {
        Text("@提及")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.overdueAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(palette.overdueAccent.opacity(0.13))
            )
    }
}

struct AgeBadgeView: View {
    let label: String
    let level: AgingLevel
    let palette: Palette

    var body: some View {
        HStack(spacing: 3.5) {
            switch level {
            case .overdue:
                Image(systemName: "clock.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(palette.overdueAccent)
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.overdueAccent)
            case .warning:
                Circle()
                    .fill(palette.warmAccent)
                    .frame(width: 5.5, height: 5.5)
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.warmAccent)
            case .fresh:
                Text(label)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(palette.tertiaryInk)
            }
        }
    }
}

struct QuietFilterButton: View {
    let app: MonitoredApp?
    let label: String?
    let count: Int
    let selected: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let app {
                    AppIconView(app: app, size: 15)
                        .opacity((count > 0 || selected) ? 1.0 : 0.48)
                }
                if let label {
                    Text(label)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? palette.primaryInk : palette.secondaryInk)
                }
                Text("\(count)")
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(selected ? palette.primaryInk : (count > 0 ? palette.secondaryInk : palette.tertiaryInk.opacity(0.75)))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? palette.subtleControlFill.opacity(1.6) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct IconActionButton: View {
    let systemName: String
    let helpText: String
    var isActive: Bool = false
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? palette.calmAccent : palette.secondaryInk)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(isActive ? palette.calmAccent.opacity(0.15) : palette.subtleControlFill)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}

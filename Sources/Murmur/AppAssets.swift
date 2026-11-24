import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AssetCatalog {
    static let shared = AssetCatalog()

    private var appIconCache: [String: NSImage] = [:]

    private init() {}

    func icon(for app: MonitoredApp) -> NSImage {
        if let cached = appIconCache[app.id] {
            return cached
        }

        for bundleId in app.mainBundleIds {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                let img = NSWorkspace.shared.icon(forFile: appURL.path)
                img.size = NSSize(width: 64, height: 64)
                appIconCache[app.id] = img
                return img
            }
        }

        let fallback = drawCleanFallbackIcon(for: app)
        appIconCache[app.id] = fallback
        return fallback
    }

    func invalidateIcon(for appId: String) {
        appIconCache.removeValue(forKey: appId)
    }

    func isAppInstalled(_ app: MonitoredApp) -> Bool {
        app.mainBundleIds.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    private func drawCleanFallbackIcon(for app: MonitoredApp) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        let img = NSImage(size: size)
        img.lockFocus()

        let rect = NSRect(x: 4, y: 4, width: 56, height: 56)
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)

        let palette: [NSColor] = [
            NSColor(calibratedRed: 0.20, green: 0.46, blue: 0.94, alpha: 1),
            NSColor(calibratedRed: 0.12, green: 0.70, blue: 0.38, alpha: 1),
            NSColor(calibratedRed: 0.36, green: 0.38, blue: 0.88, alpha: 1),
            NSColor(calibratedRed: 0.14, green: 0.60, blue: 0.78, alpha: 1)
        ]
        let colorIdx = abs(app.id.hashValue) % palette.count
        palette[colorIdx].setFill()
        path.fill()

        let firstChar = String(app.displayName.prefix(1)).uppercased()
        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: pStyle
        ]
        (firstChar as NSString).draw(in: NSRect(x: 4, y: 14, width: 56, height: 34), withAttributes: attrs)

        img.unlockFocus()
        return img
    }
}

// MARK: - Calm, Anti-Fatigue Design Tokens (Light Porcelain & Dark Graphite)

struct Palette {
    let isDark: Bool

    var surfaceFill: LinearGradient {
        if isDark {
            return LinearGradient(
                colors: [
                    Color(red: 0.165, green: 0.175, blue: 0.195).opacity(0.96),
                    Color(red: 0.135, green: 0.145, blue: 0.162).opacity(0.97)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color(red: 0.975, green: 0.975, blue: 0.965).opacity(0.97),
                    Color(red: 0.948, green: 0.948, blue: 0.938).opacity(0.98)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    var hairlineBorder: Color {
        isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.11)
    }

    var primaryInk: Color {
        isDark ? Color(red: 0.95, green: 0.95, blue: 0.94) : Color(red: 0.125, green: 0.130, blue: 0.140)
    }

    var secondaryInk: Color {
        isDark ? Color(red: 0.70, green: 0.72, blue: 0.75) : Color(red: 0.34, green: 0.36, blue: 0.39)
    }

    var tertiaryInk: Color {
        isDark ? Color(red: 0.52, green: 0.55, blue: 0.58) : Color(red: 0.52, green: 0.55, blue: 0.58)
    }

    var rowHoverFill: Color {
        isDark ? Color.white.opacity(0.055) : Color.black.opacity(0.042)
    }

    var subtleControlFill: Color {
        isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.055)
    }

    var dividerColor: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }

    var warmAccent: Color {
        isDark ? Color(red: 0.88, green: 0.72, blue: 0.42) : Color(red: 0.54, green: 0.36, blue: 0.02)
    }

    var overdueAccent: Color {
        isDark ? Color(red: 0.94, green: 0.62, blue: 0.50) : Color(red: 0.62, green: 0.24, blue: 0.16)
    }

    var calmAccent: Color {
        isDark ? Color(red: 0.45, green: 0.68, blue: 0.96) : Color(red: 0.16, green: 0.44, blue: 0.82)
    }
}

struct AppIconView: View {
    let app: MonitoredApp
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: AssetCatalog.shared.icon(for: app))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

// MARK: - Native Application Picker Helper (`/Applications`)

enum AppPickerHelper {
    @MainActor
    static func pickApplicationFromDisk(store: MessageStore) -> MonitoredApp? {
        store.isModalPickerOpen = true
        defer { store.isModalPickerOpen = false }

        let panel = NSOpenPanel()
        panel.title = "选择要加入 Murmur 监控的软件"
        panel.prompt = "添加监控"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        NSApp.activate()
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return nil
        }
        return MonitoredApp.fromApplicationBundle(url: url)
    }
}

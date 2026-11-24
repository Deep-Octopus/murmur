import Foundation
import CoreServices
import SQLite3

enum NotificationReaderState: Equatable {
    case checking
    case ready
    case accessRestricted
    case unavailable
}

final class UserNotedWatcher {
    struct RawNotification {
        let recId: Int64
        let appId: String
        let bundleId: String
        let title: String
        let subtitle: String
        let body: String
        let deliveredAt: Date
    }

    private let dbDirPath: String
    private let dbFilePath: String
    private let onNotifications: ([RawNotification], Bool) -> Void
    private let onStateChanged: (NotificationReaderState) -> Void

    private var eventStream: FSEventStreamRef?
    private var pollTimer: Timer?
    private var lastSeenRecId: Int64 = -1
    private var isInitialized = false
    private var monitoredApps: [MonitoredApp] = MonitoredApp.defaultApps
    private let queue = DispatchQueue(label: "io.github.deep-octopus.Murmur.usernoted", qos: .utility)

    init(
        initialApps: [MonitoredApp],
        onNotifications: @escaping ([RawNotification], Bool) -> Void,
        onStateChanged: @escaping (NotificationReaderState) -> Void
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.dbDirPath = "\(home)/Library/Group Containers/group.com.apple.usernoted/db2"
        self.dbFilePath = "\(self.dbDirPath)/db"
        self.monitoredApps = initialApps
        self.onNotifications = onNotifications
        self.onStateChanged = onStateChanged
    }

    func updateMonitoredApps(_ apps: [MonitoredApp]) {
        queue.async { [weak self] in
            self?.monitoredApps = apps.filter(\.isEnabled)
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.pollDatabase()
        }
        startFSEvents()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.queue.async {
                self?.pollDatabase()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }

    private func startFSEvents() {
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, clientCallBackInfo, _, _, _, _) in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<UserNotedWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.queue.asyncAfter(deadline: .now() + 0.14) {
                watcher.pollDatabase()
            }
        }

        let pathsToWatch = [dbDirPath] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            return
        }

        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func pollDatabase() {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let openRc = sqlite3_open_v2(dbFilePath, &db, flags, nil)
        guard openRc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            publishState(.accessRestricted)
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 350)

        guard let currentMaxId = queryMaxRecId(db: db) else {
            publishState(.accessRestricted)
            return
        }

        publishState(.ready)

        if isInitialized && currentMaxId < lastSeenRecId {
            lastSeenRecId = max(0, currentMaxId - 100)
        }

        if !isInitialized {
            let startupBatch = fetchStartupBackfill(db: db, upToRecId: currentMaxId)
            lastSeenRecId = currentMaxId
            isInitialized = true
            if !startupBatch.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.onNotifications(startupBatch, true)
                }
            }
            return
        }

        guard currentMaxId > lastSeenRecId else { return }

        let liveBatch = fetchIncremental(db: db, afterRecId: lastSeenRecId, upToRecId: currentMaxId)
        if !liveBatch.items.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onNotifications(liveBatch.items, false)
            }
        }
        if liveBatch.newCursor > lastSeenRecId {
            lastSeenRecId = liveBatch.newCursor
        }
    }

    private func publishState(_ state: NotificationReaderState) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged(state)
        }
    }

    private func queryMaxRecId(db: OpaquePointer) -> Int64? {
        let sql = "SELECT COALESCE(MAX(rec_id), 0) FROM record;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func fetchStartupBackfill(db: OpaquePointer, upToRecId: Int64) -> [RawNotification] {
        let minRefDate = Date().addingTimeInterval(-8 * 3600).timeIntervalSinceReferenceDate
        let sql = """
        SELECT r.rec_id, a.identifier, r.data, r.delivered_date
        FROM record r
        LEFT JOIN app a ON r.app_id = a.app_id
        WHERE r.rec_id <= ? AND r.delivered_date >= ?
        ORDER BY r.rec_id DESC
        LIMIT 250;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, upToRecId)
        sqlite3_bind_double(stmt, 2, minRefDate)

        var descending: [RawNotification] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recId = sqlite3_column_int64(stmt, 0)
            if let parsed = parseRow(stmt: stmt, recId: recId) {
                descending.append(parsed)
                if descending.count >= 60 { break }
            }
        }
        return descending.reversed()
    }

    private func fetchIncremental(
        db: OpaquePointer,
        afterRecId: Int64,
        upToRecId: Int64
    ) -> (items: [RawNotification], newCursor: Int64) {
        let sql = """
        SELECT r.rec_id, a.identifier, r.data, r.delivered_date
        FROM record r
        LEFT JOIN app a ON r.app_id = a.app_id
        WHERE r.rec_id > ? AND r.rec_id <= ?
        ORDER BY r.rec_id ASC
        LIMIT 150;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return ([], afterRecId)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, afterRecId)
        sqlite3_bind_int64(stmt, 2, upToRecId)

        var results: [RawNotification] = []
        var cursor = afterRecId
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recId = sqlite3_column_int64(stmt, 0)
            if recId > cursor { cursor = recId }
            if let parsed = parseRow(stmt: stmt, recId: recId) {
                results.append(parsed)
            }
        }
        return (results, cursor)
    }

    private func resolveApp(bundleId: String) -> MonitoredApp? {
        monitoredApps.first { $0.isEnabled && $0.matchesBundleId(bundleId) }
    }

    private func parseRow(stmt: OpaquePointer, recId: Int64) -> RawNotification? {
        var joinedBundle = ""
        if let cStr = sqlite3_column_text(stmt, 1) {
            joinedBundle = String(cString: cStr)
        }

        let blobBytes = sqlite3_column_blob(stmt, 2)
        let blobLen = Int(sqlite3_column_bytes(stmt, 2))
        let deliveredRef = sqlite3_column_double(stmt, 3)
        let deliveredDate = deliveredRef > 0
            ? Date(timeIntervalSinceReferenceDate: deliveredRef)
            : Date()

        guard let blobBytes, blobLen > 0 else { return nil }
        let data = Data(bytes: blobBytes, count: blobLen)

        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let plistBundle = (plist["app"] as? String) ?? ""
        let matched = resolveApp(bundleId: joinedBundle) ?? resolveApp(bundleId: plistBundle)
        guard let targetApp = matched else { return nil }

        let req = plist["req"] as? [String: Any] ?? plist
        let title = Self.extractText(req["titl"]) ?? Self.extractText(req["title"]) ?? ""
        let subtitle = Self.extractText(req["subt"]) ?? Self.extractText(req["subtitle"]) ?? ""
        let body = Self.extractText(req["body"]) ?? Self.extractText(req["mesg"]) ?? ""

        let resolvedTitle = title.isEmpty ? targetApp.displayName : title
        let resolvedBody = (title.isEmpty && subtitle.isEmpty && body.isEmpty)
            ? "收到新通知（系统通知详情已隐藏）"
            : body

        return RawNotification(
            recId: recId,
            appId: targetApp.id,
            bundleId: targetApp.primaryBundleId,
            title: resolvedTitle,
            subtitle: subtitle,
            body: resolvedBody,
            deliveredAt: deliveredDate
        )
    }

    private static func extractText(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let str = raw as? String {
            let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let attr = raw as? NSAttributedString {
            let t = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let dict = raw as? [String: Any] {
            if let s = dict["NS.string"] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            if let args = dict["loc-args"] as? [Any] {
                let joined = args.compactMap { extractText($0) }.joined(separator: " ")
                if !joined.isEmpty { return joined }
            }
        }
        if let arr = raw as? [Any] {
            let joined = arr.compactMap { extractText($0) }.joined(separator: " ")
            if !joined.isEmpty { return joined }
        }
        return nil
    }
}

import Foundation
import SQLite

class OfflineQueue {
    private var db: Connection!

    private let table = Table("queued_messages")
    private let colLocalId = Expression<String>("local_id")
    private let colServerId = Expression<String?>("server_id")
    private let colToUser = Expression<String>("to_user")
    private let colText = Expression<String>("text")
    private let colQueuedAt = Expression<Int64>("queued_at")
    private let colStatus = Expression<String>("status")

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".messaging-cli")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("queue.db").path
        db = try! Connection(dbPath)
        createTable()
    }

    private func createTable() {
        try! db.run(table.create(ifNotExists: true) { t in
            t.column(colLocalId, primaryKey: true)
            t.column(colServerId)
            t.column(colToUser)
            t.column(colText)
            t.column(colQueuedAt)
            t.column(colStatus, defaultValue: "pending")
        })
    }

    func enqueue(to: String, text: String) -> String {
        let localId = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try! db.run(table.insert(
            colLocalId <- localId,
            colServerId <- nil,
            colToUser <- to,
            colText <- text,
            colQueuedAt <- now,
            colStatus <- QueuedStatus.pending.rawValue
        ))
        return localId
    }

    func nextPending() -> QueuedMessage? {
        let query = table
            .filter(colStatus == QueuedStatus.pending.rawValue)
            .order(colQueuedAt.asc)
            .limit(1)
        guard let row = try? db.pluck(query) else { return nil }
        return QueuedMessage(
            localId: row[colLocalId],
            serverId: row[colServerId],
            toUser: row[colToUser],
            text: row[colText],
            queuedAt: row[colQueuedAt],
            status: QueuedStatus(rawValue: row[colStatus]) ?? .pending
        )
    }

    func markSending(localId: String) {
        let row = table.filter(colLocalId == localId)
        try? db.run(row.update(colStatus <- QueuedStatus.sending.rawValue))
    }

    func markSent(localId: String, serverId: String) {
        let row = table.filter(colLocalId == localId)
        try? db.run(row.update(colStatus <- QueuedStatus.sent.rawValue, colServerId <- serverId))
    }

    func markFailed(localId: String) {
        let row = table.filter(colLocalId == localId)
        try? db.run(row.update(colStatus <- QueuedStatus.failed.rawValue))
    }

    func markPending(localId: String) {
        let row = table.filter(colLocalId == localId)
        try? db.run(row.update(colStatus <- QueuedStatus.pending.rawValue))
    }

    func isDuplicate(serverId: String) -> Bool {
        let query = table.filter(colServerId == serverId)
        return ((try? db.scalar(query.count)) ?? 0) > 0
    }
}

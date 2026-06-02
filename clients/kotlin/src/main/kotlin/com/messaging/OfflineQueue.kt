package com.messaging

import org.jetbrains.exposed.sql.*
import org.jetbrains.exposed.sql.transactions.transaction
import java.io.File
import java.util.UUID

object QueuedMessages : Table("queued_messages") {
    val localId  = varchar("local_id", 36)
    val serverId = varchar("server_id", 36).nullable()
    val toUser   = varchar("to_user", 255)
    val text     = text("text")
    val queuedAt = long("queued_at")
    val status   = varchar("status", 20).default("pending")
    override val primaryKey = PrimaryKey(localId)
}

class OfflineQueue {
    // Not connected until initialize(username) is called after login.
    // A shared queue.db causes isDuplicate() to match the other user's sent
    // message IDs, silently dropping all received messages.
    private var db: Database? = null

    fun initialize(username: String) {
        val dir = File(System.getProperty("user.home"), ".messaging-cli/$username")
        dir.mkdirs()
        val dbPath = File(dir, "queue.db").absolutePath
        db = Database.connect("jdbc:sqlite:$dbPath", "org.sqlite.JDBC")
        transaction(db) { SchemaUtils.create(QueuedMessages) }
    }

    fun enqueue(to: String, text: String): String {
        val localId = UUID.randomUUID().toString()
        val d = db ?: return localId
        transaction(d) {
            QueuedMessages.insert {
                it[QueuedMessages.localId] = localId
                it[toUser]   = to
                it[QueuedMessages.text]    = text
                it[queuedAt] = System.currentTimeMillis()
                it[status]   = "pending"
            }
        }
        return localId
    }

    fun nextPending(): QueuedMessage? {
        val d = db ?: return null
        return transaction(d) {
            QueuedMessages
                .select { QueuedMessages.status eq "pending" }
                .orderBy(QueuedMessages.queuedAt to SortOrder.ASC)
                .limit(1).firstOrNull()?.toQueuedMessage()
        }
    }

    fun markSending(localId: String) {
        val d = db ?: return
        transaction(d) { QueuedMessages.update({ QueuedMessages.localId eq localId }) { it[status] = "sending" } }
    }

    fun markSent(localId: String, serverId: String) {
        val d = db ?: return
        transaction(d) {
            QueuedMessages.update({ QueuedMessages.localId eq localId }) {
                it[QueuedMessages.serverId] = serverId
                it[status] = "sent"
            }
        }
    }

    fun markFailed(localId: String) {
        val d = db ?: return
        transaction(d) { QueuedMessages.update({ QueuedMessages.localId eq localId }) { it[status] = "failed" } }
    }

    fun markPending(localId: String) {
        val d = db ?: return
        transaction(d) { QueuedMessages.update({ QueuedMessages.localId eq localId }) { it[status] = "pending" } }
    }

    fun isDuplicate(serverId: String): Boolean {
        val d = db ?: return false
        return transaction(d) {
            QueuedMessages.select { QueuedMessages.serverId eq serverId }.count() > 0
        }
    }

    private fun ResultRow.toQueuedMessage() = QueuedMessage(
        localId  = this[QueuedMessages.localId],
        serverId = this[QueuedMessages.serverId],
        toUser   = this[QueuedMessages.toUser],
        text     = this[QueuedMessages.text],
        queuedAt = this[QueuedMessages.queuedAt],
        status   = MessageStatus.valueOf(this[QueuedMessages.status].uppercase())
    )
}

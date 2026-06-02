package com.messaging

import org.jetbrains.exposed.sql.*
import org.jetbrains.exposed.sql.transactions.transaction
import java.io.File
import java.util.UUID

object QueuedMessages : Table("queued_messages") {
    val localId = varchar("local_id", 36)
    val serverId = varchar("server_id", 36).nullable()
    val toUser = varchar("to_user", 255)
    val text = text("text")
    val queuedAt = long("queued_at")
    val status = varchar("status", 20).default("pending")

    override val primaryKey = PrimaryKey(localId)
}

class OfflineQueue {
    init {
        val dir = File(System.getProperty("user.home"), ".messaging-cli")
        dir.mkdirs()
        val dbPath = File(dir, "queue.db").absolutePath
        Database.connect("jdbc:sqlite:$dbPath", "org.sqlite.JDBC")
        transaction {
            SchemaUtils.create(QueuedMessages)
        }
    }

    fun enqueue(to: String, text: String): String {
        val localId = UUID.randomUUID().toString()
        transaction {
            QueuedMessages.insert {
                it[QueuedMessages.localId] = localId
                it[toUser] = to
                it[QueuedMessages.text] = text
                it[queuedAt] = System.currentTimeMillis()
                it[status] = "pending"
            }
        }
        return localId
    }

    fun nextPending(): QueuedMessage? = transaction {
        QueuedMessages
            .select { QueuedMessages.status eq "pending" }
            .orderBy(QueuedMessages.queuedAt to SortOrder.ASC)
            .limit(1)
            .firstOrNull()
            ?.toQueuedMessage()
    }

    fun markSending(localId: String) = transaction {
        QueuedMessages.update({ QueuedMessages.localId eq localId }) {
            it[status] = "sending"
        }
    }

    fun markSent(localId: String, serverId: String) = transaction {
        QueuedMessages.update({ QueuedMessages.localId eq localId }) {
            it[QueuedMessages.serverId] = serverId
            it[status] = "sent"
        }
    }

    fun markFailed(localId: String) = transaction {
        QueuedMessages.update({ QueuedMessages.localId eq localId }) {
            it[status] = "failed"
        }
    }

    fun markPending(localId: String) = transaction {
        QueuedMessages.update({ QueuedMessages.localId eq localId }) {
            it[status] = "pending"
        }
    }

    fun isDuplicate(serverId: String): Boolean = transaction {
        QueuedMessages
            .select { QueuedMessages.serverId eq serverId }
            .count() > 0
    }

    private fun ResultRow.toQueuedMessage() = QueuedMessage(
        localId = this[QueuedMessages.localId],
        serverId = this[QueuedMessages.serverId],
        toUser = this[QueuedMessages.toUser],
        text = this[QueuedMessages.text],
        queuedAt = this[QueuedMessages.queuedAt],
        status = MessageStatus.valueOf(this[QueuedMessages.status].uppercase())
    )
}

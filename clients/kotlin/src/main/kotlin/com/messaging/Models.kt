package com.messaging

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

enum class MessageStatus { PENDING, SENDING, SENT, FAILED }

@Serializable
data class WireMessage(
    val id: String,
    @SerialName("from") val fromUser: String,
    val to: String,
    val text: String,
    val timestamp: Long,
    val status: String
)

@Serializable
data class QueuedMessage(
    val localId: String,
    val serverId: String?,
    val toUser: String,
    val text: String,
    val queuedAt: Long,
    val status: MessageStatus
)

@Serializable
data class RegisterRequest(val username: String, val password: String)

@Serializable
data class LoginRequest(val username: String, val password: String)

@Serializable
data class SendRequest(val to: String, val text: String)

@Serializable
data class RegisterResponse(val userId: String, val username: String)

@Serializable
data class LoginResponse(val userId: String, val username: String, val sessionId: String)

@Serializable
data class SendResponse(val id: String, val timestamp: Long)

@Serializable
data class MessagesResponse(val messages: List<WireMessage>, val serverTimestamp: Long)

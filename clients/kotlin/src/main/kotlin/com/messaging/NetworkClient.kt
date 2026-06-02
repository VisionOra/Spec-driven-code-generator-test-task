package com.messaging

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.ConnectException
import java.net.SocketException

class NetworkClient {
    private val http = OkHttpClient()
    private val json = Json { ignoreUnknownKeys = true }
    private val JSON_TYPE = "application/json; charset=utf-8".toMediaType()

    suspend fun register(username: String, password: String, serverURL: String): RegisterResponse =
        withContext(Dispatchers.IO) {
            try {
                val body = json.encodeToString(RegisterRequest(username, password))
                val request = Request.Builder()
                    .url("$serverURL/register")
                    .post(body.toRequestBody(JSON_TYPE))
                    .build()
                http.newCall(request).execute().use { response ->
                    when (response.code) {
                        201 -> json.decodeFromString(response.body!!.string())
                        409 -> throw NetworkError.UsernameTaken
                        else -> throw NetworkError.ServerError(response.code)
                    }
                }
            } catch (e: NetworkError) {
                throw e
            } catch (e: ConnectException) {
                throw NetworkError.ConnectionFailed
            } catch (e: SocketException) {
                throw NetworkError.ConnectionFailed
            }
        }

    suspend fun login(username: String, password: String, serverURL: String): LoginResponse =
        withContext(Dispatchers.IO) {
            try {
                val body = json.encodeToString(LoginRequest(username, password))
                val request = Request.Builder()
                    .url("$serverURL/login")
                    .post(body.toRequestBody(JSON_TYPE))
                    .build()
                http.newCall(request).execute().use { response ->
                    when (response.code) {
                        200 -> json.decodeFromString(response.body!!.string())
                        401 -> throw NetworkError.Unauthorized
                        else -> throw NetworkError.ServerError(response.code)
                    }
                }
            } catch (e: NetworkError) {
                throw e
            } catch (e: ConnectException) {
                throw NetworkError.ConnectionFailed
            } catch (e: SocketException) {
                throw NetworkError.ConnectionFailed
            }
        }

    suspend fun send(to: String, text: String, sessionId: String, serverURL: String): SendResponse =
        withContext(Dispatchers.IO) {
            try {
                val body = json.encodeToString(SendRequest(to, text))
                val request = Request.Builder()
                    .url("$serverURL/send")
                    .header("X-Session-Id", sessionId)
                    .post(body.toRequestBody(JSON_TYPE))
                    .build()
                http.newCall(request).execute().use { response ->
                    when (response.code) {
                        200 -> json.decodeFromString(response.body!!.string())
                        401 -> throw NetworkError.Unauthorized
                        else -> throw NetworkError.ServerError(response.code)
                    }
                }
            } catch (e: NetworkError) {
                throw e
            } catch (e: ConnectException) {
                throw NetworkError.ConnectionFailed
            } catch (e: SocketException) {
                throw NetworkError.ConnectionFailed
            }
        }

    suspend fun getMessages(since: Long, sessionId: String, serverURL: String): MessagesResponse =
        withContext(Dispatchers.IO) {
            try {
                val request = Request.Builder()
                    .url("$serverURL/messages?since=$since")
                    .header("X-Session-Id", sessionId)
                    .get()
                    .build()
                http.newCall(request).execute().use { response ->
                    when (response.code) {
                        200 -> json.decodeFromString(response.body!!.string())
                        401 -> throw NetworkError.Unauthorized
                        else -> throw NetworkError.ServerError(response.code)
                    }
                }
            } catch (e: NetworkError) {
                throw e
            } catch (e: ConnectException) {
                throw NetworkError.ConnectionFailed
            } catch (e: SocketException) {
                throw NetworkError.ConnectionFailed
            }
        }

    suspend fun logout(sessionId: String, serverURL: String): Unit =
        withContext(Dispatchers.IO) {
            try {
                val request = Request.Builder()
                    .url("$serverURL/logout")
                    .header("X-Session-Id", sessionId)
                    .post("{}".toRequestBody(JSON_TYPE))
                    .build()
                http.newCall(request).execute().use { }
            } catch (e: Exception) {
                // best-effort
            }
        }
}

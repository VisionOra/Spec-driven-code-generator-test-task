package com.messaging

import kotlinx.coroutines.*

enum class ClientState { LOGGED_OUT, REGISTERING, LOGGING_IN, ONLINE, FLUSHING, OFFLINE }

class MessageClient(
    private val serverURL: String,
    private val networkMonitor: NetworkMonitor,
    private val networkClient: NetworkClient = NetworkClient(),
    private val offlineQueue: OfflineQueue = OfflineQueue()
) {
    var onMessageReceived: ((WireMessage) -> Unit)? = null
    var onStateChange: ((String) -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    @Volatile private var state: ClientState = ClientState.LOGGED_OUT
    @Volatile private var sessionId: String? = null
    @Volatile private var lastServerTimestamp: Long = 0L
    private var currentJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    init {
        networkMonitor.onStatusChange = { isOnline ->
            scope.launch {
                if (!isOnline) {
                    if (state == ClientState.ONLINE || state == ClientState.FLUSHING) {
                        currentJob?.cancel()
                        setState(ClientState.OFFLINE)
                    }
                } else {
                    if (state == ClientState.OFFLINE) {
                        if (offlineQueue.nextPending() != null) {
                            setState(ClientState.FLUSHING)
                            currentJob = scope.launch { runFlushQueue() }
                        } else {
                            setState(ClientState.ONLINE)
                            startSyncLoop()
                        }
                    }
                }
            }
        }
    }

    private fun setState(newState: ClientState) {
        state = newState
        onStateChange?.invoke(newState.name)
    }

    suspend fun register(username: String, password: String) {
        setState(ClientState.REGISTERING)
        try {
            networkClient.register(username, password, serverURL)
            setState(ClientState.LOGGED_OUT)
        } catch (e: NetworkError.UsernameTaken) {
            onError?.invoke("username_taken")
            setState(ClientState.LOGGED_OUT)
        } catch (e: NetworkError) {
            onError?.invoke("connection_failed")
            setState(ClientState.LOGGED_OUT)
        }
    }

    suspend fun login(username: String, password: String) {
        setState(ClientState.LOGGING_IN)
        try {
            val response = networkClient.login(username, password, serverURL)
            sessionId = response.sessionId
            setState(ClientState.ONLINE)
            startSyncLoop()
        } catch (e: NetworkError.Unauthorized) {
            onError?.invoke("invalid_credentials")
            setState(ClientState.LOGGED_OUT)
        } catch (e: NetworkError) {
            onError?.invoke("connection_failed")
            setState(ClientState.LOGGED_OUT)
        }
    }

    suspend fun sendMessage(to: String, text: String) {
        val localId = offlineQueue.enqueue(to, text)
        if (state == ClientState.ONLINE) {
            val sid = sessionId
            if (sid == null) {
                offlineQueue.markPending(localId)
                return
            }
            offlineQueue.markSending(localId)
            try {
                val response = networkClient.send(to, text, sid, serverURL)
                offlineQueue.markSent(localId, response.id)
            } catch (e: NetworkError.Unauthorized) {
                offlineQueue.markPending(localId)
                sessionId = null
                currentJob?.cancel()
                setState(ClientState.LOGGED_OUT)
            } catch (e: NetworkError.ConnectionFailed) {
                offlineQueue.markPending(localId)
                currentJob?.cancel()
                setState(ClientState.OFFLINE)
            } catch (e: NetworkError) {
                offlineQueue.markFailed(localId)
                setState(ClientState.FLUSHING)
                currentJob = scope.launch { runFlushQueue() }
            }
        }
        // OFFLINE or FLUSHING: already enqueued, nothing more to do
    }

    suspend fun logout() {
        try {
            sessionId?.let { networkClient.logout(it, serverURL) }
        } catch (e: Exception) {
            // best-effort
        }
        sessionId = null
        currentJob?.cancel()
        setState(ClientState.LOGGED_OUT)
    }

    private fun startSyncLoop() {
        currentJob?.cancel()
        currentJob = scope.launch {
            // immediate first poll on transition to ONLINE
            poll()
            while (isActive && state == ClientState.ONLINE) {
                delay(3000)
                if (state == ClientState.ONLINE) poll()
            }
        }
    }

    private suspend fun poll() {
        val sid = sessionId ?: return
        try {
            val response = networkClient.getMessages(lastServerTimestamp, sid, serverURL)
            lastServerTimestamp = response.serverTimestamp
            response.messages.forEach { msg ->
                if (!offlineQueue.isDuplicate(msg.id)) {
                    onMessageReceived?.invoke(msg)
                }
            }
        } catch (e: NetworkError.Unauthorized) {
            sessionId = null
            setState(ClientState.LOGGED_OUT)
        } catch (e: NetworkError.ConnectionFailed) {
            setState(ClientState.OFFLINE)
        } catch (e: NetworkError) {
            // transient error — continue
        }
    }

    private suspend fun runFlushQueue() {
        while (state == ClientState.FLUSHING) {
            val msg = offlineQueue.nextPending() ?: break
            val sid = sessionId
            if (sid == null) {
                setState(ClientState.LOGGED_OUT)
                return
            }
            offlineQueue.markSending(msg.localId)
            try {
                val response = networkClient.send(msg.toUser, msg.text, sid, serverURL)
                offlineQueue.markSent(msg.localId, response.id)
            } catch (e: NetworkError.Unauthorized) {
                offlineQueue.markPending(msg.localId)
                sessionId = null
                setState(ClientState.LOGGED_OUT)
                return
            } catch (e: NetworkError.ConnectionFailed) {
                offlineQueue.markPending(msg.localId)
                setState(ClientState.OFFLINE)
                return
            } catch (e: NetworkError.ServerError) {
                offlineQueue.markFailed(msg.localId)
                // 5xx: log and continue to next message
            } catch (e: NetworkError) {
                offlineQueue.markFailed(msg.localId)
            }
        }
        if (state == ClientState.FLUSHING) {
            setState(ClientState.ONLINE)
            startSyncLoop()
        }
    }
}

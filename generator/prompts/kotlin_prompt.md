You are generating a Kotlin JVM CLI messaging client. Write all source files directly to disk using your file tools.

Output directory: {{OUTPUT_DIR}}

Write every file listed below to that exact directory. Do not ask for permission — just write the files.

## Environment
- Kotlin 1.9+, JDK 17, Gradle (build.gradle already exists — do NOT modify it)
- HTTP: OkHttp 4.x (already in build.gradle)
- JSON: kotlinx.serialization (already in build.gradle)
- Local storage: Exposed + sqlite-jdbc (already in build.gradle)
- Async: Kotlin coroutines (already in build.gradle)
- Package: `com.messaging`
- Main class: `com.messaging.MainKt`

## Spec
{{SPEC}}

## Files to write

Write each file to `{{OUTPUT_DIR}}/<FileName.kt>` with `package com.messaging` at the top.

**Models.kt**
- All data classes annotated with `@Serializable`
- `WireMessage`: id, from, to, text, timestamp (Long), status — use `@SerialName("from")` for the `from` field since it conflicts with Kotlin
- `QueuedMessage`: localId, serverId (String?), toUser, text, queuedAt (Long), status (MessageStatus)
- `MessageStatus` enum: PENDING, SENDING, SENT, FAILED
- `RegisterResponse`: userId, username
- `LoginResponse`: userId, username, sessionId
- `SendResponse`: id, timestamp (Long)
- `MessagesResponse`: messages (List<WireMessage>), serverTimestamp (Long)

**NetworkError.kt**
- `sealed class NetworkError : Exception()`
- Subclasses: `Unauthorized`, `UsernameTaken`, `ServerError(val code: Int)`, `ConnectionFailed`

**NetworkClient.kt** — OkHttp wrapper (class NetworkClient):
- All methods are suspend functions, run OkHttp calls via `withContext(Dispatchers.IO)`
- `suspend fun register(username: String, password: String, serverURL: String): RegisterResponse`
- `suspend fun login(username: String, password: String, serverURL: String): LoginResponse`
- `suspend fun send(to: String, text: String, sessionId: String, serverURL: String): SendResponse`
- `suspend fun getMessages(since: Long, sessionId: String, serverURL: String): MessagesResponse`
- `suspend fun logout(sessionId: String, serverURL: String)`
- POST requests: body is JSON, `Content-Type: application/json`
- Authenticated requests: `X-Session-Id: <sessionId>` header
- HTTP 401 → throw Unauthorized; HTTP 409 → throw UsernameTaken; other 4xx/5xx → throw ServerError(code)
- java.net.ConnectException / java.net.SocketException → throw ConnectionFailed

**OfflineQueue.kt** — Exposed + SQLite (class OfflineQueue):
- Database at `~/.messaging-cli/queue.db`; create parent dir if missing; connect with `Database.connect`
- Use `SchemaUtils.create` on init; use `transaction { }` for all DB ops
- Table object `QueuedMessages` with columns matching spec section 6
- `fun enqueue(to: String, text: String): String` — returns localId
- `fun nextPending(): QueuedMessage?`
- `fun markSending(localId: String)`
- `fun markSent(localId: String, serverId: String)`
- `fun markFailed(localId: String)`
- `fun markPending(localId: String)`
- `fun isDuplicate(serverId: String): Boolean`

**NetworkMonitor.kt** — CLI connectivity simulation (class NetworkMonitor):
- `var isOnline: Boolean = true`
- `var onStatusChange: ((Boolean) -> Unit)? = null`
- `fun setOffline()` — sets isOnline=false, calls onStatusChange(false)
- `fun setOnline()` — sets isOnline=true, calls onStatusChange(true)

**MessageClient.kt** — state machine + coroutine orchestrator (class MessageClient):
- States: sealed class or enum — LOGGED_OUT, REGISTERING, LOGGING_IN, ONLINE, FLUSHING, OFFLINE
- `var onMessageReceived: ((WireMessage) -> Unit)? = null`
- `var onStateChange: ((String) -> Unit)? = null`
- `var onError: ((String) -> Unit)? = null`
- `suspend fun register(username: String, password: String)`
  - LOGGED_OUT → REGISTERING → LOGGED_OUT (success) or LOGGED_OUT (UsernameTaken: call onError("username_taken"))
- `suspend fun login(username: String, password: String)`
  - LOGGED_OUT → LOGGING_IN → ONLINE (start sync loop) or LOGGED_OUT (Unauthorized: call onError("invalid_credentials"))
- `suspend fun sendMessage(to: String, text: String)`
  - ONLINE: enqueue + POST /send immediately; failure → FLUSHING
  - OFFLINE/FLUSHING: enqueue only
- `suspend fun logout()`
  - Best-effort POST /logout; clear session; → LOGGED_OUT
- Sync loop: coroutine polling GET /messages every 3s when ONLINE; on new messages call onMessageReceived; deduplicate via isDuplicate
- Flush loop: implement flushQueue from spec as a coroutine; when queue empty → ONLINE
- On 401 from any call: clear session → LOGGED_OUT
- On ConnectionFailed: → OFFLINE
- Wire NetworkMonitor.onStatusChange: offline→online triggers FLUSHING (if queue non-empty) or ONLINE; online→offline triggers OFFLINE

**Main.kt** — CLI entry point:
- `fun main(args: Array<String>)` using `runBlocking`
- Parse: `--user <name>`, `--password <pass>`, `--server <url>` (default: http://localhost:8765)
- If --user and --password not both provided: prompt interactively
  - Print "register or login? " → readLine()
  - Print "username: " → readLine()
  - Print "password: " → readLine()
- Wire MessageClient callbacks:
  - onMessageReceived: println("RECEIVED from \${msg.fromUser}: \${msg.text}")
  - onStateChange: println("STATE: \$state")
  - onError: println("ERROR: \$reason")
- Wire NetworkMonitor to MessageClient
- If args provided: call client.login(user, password) directly
- Otherwise: call register or login based on prompt
- Stdin loop (use a coroutine or thread to not block):
  - `send <username> <message>` → client.sendMessage
  - `offline` → networkMonitor.setOffline()
  - `online` → networkMonitor.setOnline()
  - `quit` → client.logout(); exitProcess(0)

## Requirements
- No chat or messaging SDKs
- Must compile with: `./gradlew compileKotlin` from clients/kotlin directory
- Must run: `./gradlew run --args="--user bob --password secret"`

IMPORTANT: You are in pure text output mode with file-write tools available. Write all source files directly to disk using your file tools. Do not explain — just write the files.

Output directory: {{OUTPUT_DIR}}

You are generating a Kotlin JVM CLI messaging client that implements the spec below.

## Environment
- Kotlin 1.9+, JDK 17, Gradle (build.gradle and settings.gradle already exist — do NOT modify them)
- HTTP: OkHttp 4.x (already in build.gradle)
- JSON: kotlinx.serialization (already in build.gradle)
- Local storage: Exposed + sqlite-jdbc (already in build.gradle)
- Async: Kotlin coroutines (already in build.gradle)
- Package: `com.messaging` — every file starts with `package com.messaging`
- Main class: `com.messaging.MainKt`

## Spec
{{SPEC}}

## Files to write

Write each file to `{{OUTPUT_DIR}}/<FileName.kt>`.

---

### Models.kt
All data classes annotated with `@Serializable`:

```kotlin
// WireMessage — from server GET /messages
@Serializable
data class WireMessage(
    val id: String,
    @SerialName("from") val fromUser: String,
    val to: String,
    val text: String,
    val timestamp: Long,
    val status: String
)

enum class MessageStatus { PENDING, SENDING, SENT, FAILED }

data class QueuedMessage(
    val localId: String,
    val serverId: String?,
    val toUser: String,
    val text: String,
    val queuedAt: Long,
    val status: MessageStatus
)

@Serializable data class RegisterResponse(val userId: String, val username: String)
@Serializable data class LoginResponse(val userId: String, val username: String, val sessionId: String)
@Serializable data class SendResponse(val id: String, val timestamp: Long)
@Serializable data class MessagesResponse(val messages: List<WireMessage>, val serverTimestamp: Long)

@Serializable data class InboxEntry(val contact: String, val unread: Int, val lastTimestamp: Long)
@Serializable data class InboxResponse(val inbox: List<InboxEntry>)

@Serializable
data class ConversationMessage(
    val id: String,
    @SerialName("from_user") val fromUser: String,
    @SerialName("to_user") val toUser: String,
    val text: String,
    val timestamp: Long,
    val read: Int
)
@Serializable data class ConversationResponse(val messages: List<ConversationMessage>)
```

---

### NetworkError.kt
```kotlin
sealed class NetworkError : Exception() {
    object Unauthorized : NetworkError()
    object UsernameTaken : NetworkError()
    data class ServerError(val code: Int) : NetworkError()
    object ConnectionFailed : NetworkError()
}
```

---

### NetworkClient.kt
OkHttp wrapper — class NetworkClient. All methods are suspend functions using `withContext(Dispatchers.IO)`:

- `suspend fun register(username: String, password: String, serverURL: String): RegisterResponse`
  POST /register — 409 → UsernameTaken, 401 → Unauthorized
- `suspend fun login(username: String, password: String, serverURL: String): LoginResponse`
  POST /login — 401 → Unauthorized
- `suspend fun send(to: String, text: String, sessionId: String, serverURL: String): SendResponse`
  POST /send
- `suspend fun getMessages(since: Long, sessionId: String, serverURL: String): MessagesResponse`
  GET /messages?since=<since>
- `suspend fun getInbox(sessionId: String, serverURL: String): InboxResponse`
  GET /inbox
- `suspend fun getConversation(with: String, sessionId: String, serverURL: String): ConversationResponse`
  GET /conversation/<with>
- `suspend fun markRead(fromUser: String, sessionId: String, serverURL: String)`
  POST /mark-read { "fromUser": fromUser } — best-effort, swallow errors
- `suspend fun logout(sessionId: String, serverURL: String)`
  POST /logout — best-effort

Rules:
- All POST: Content-Type: application/json body built manually as JSON string
- All authenticated calls: X-Session-Id header
- HTTP 401 → throw Unauthorized; HTTP 409 → throw UsernameTaken; other 4xx/5xx → throw ServerError(code)
- java.net.ConnectException, java.net.SocketException, java.net.SocketTimeoutException → throw ConnectionFailed

---

### OfflineQueue.kt
Exposed + SQLite — class OfflineQueue:

- `constructor(username: String)` — DB file at `~/.messaging-cli/<username>/queue.db`
  Create parent directory if missing. MUST be user-scoped: shared DB causes isDuplicate()
  to suppress incoming messages from other users on the same machine.
- Connect with `Database.connect("jdbc:sqlite:<path>", "org.sqlite.JDBC")`
- Define `object QueuedMessages : Table("queued_messages")` with columns matching spec schema
- `SchemaUtils.create(QueuedMessages)` on init inside a `transaction {}`
- `fun enqueue(to: String, text: String): String` — insert pending row, return new UUID
- `fun nextPending(): QueuedMessage?` — oldest pending row
- `fun markSending(localId: String)`
- `fun markSent(localId: String, serverId: String)`
- `fun markFailed(localId: String)`
- `fun markPending(localId: String)`
- `fun isDuplicate(serverId: String): Boolean` — true if any row has server_id == serverId

---

### NetworkMonitor.kt
CLI connectivity simulation — class NetworkMonitor:

- `var isOnline: Boolean = true`
- `var onStatusChange: ((Boolean) -> Unit)? = null`
- `fun setOffline()` — isOnline=false; call onStatusChange(false)
- `fun setOnline()` — isOnline=true; call onStatusChange(true)

---

### MessageClient.kt
State machine + coroutine orchestrator — class MessageClient:

```kotlin
enum class ClientState { LOGGED_OUT, REGISTERING, LOGGING_IN, ONLINE, FLUSHING, OFFLINE }
```

Properties:
- `val networkMonitor = NetworkMonitor()`
- `var onNewMessage: ((WireMessage) -> Unit)? = null`
- `var onStateChange: ((String) -> Unit)? = null`
- `var onError: ((String) -> Unit)? = null`
- private: network, queue (OfflineQueue?, created on login), sessionId, currentUser,
  lastServerTimestamp, syncJob, state, scope (CoroutineScope with SupervisorJob)

Methods:
- `suspend fun register(username: String, password: String): Boolean`
  - → REGISTERING → LOGGED_OUT (true) or LOGGED_OUT with onError (false)
  - UsernameTaken: onError("That username is already taken.")
  - ConnectionFailed: onError("Cannot reach server — is it running?")
- `suspend fun login(username: String, password: String): Boolean`
  - → LOGGING_IN → ONLINE (create OfflineQueue(username), start sync loop; true)
  - Unauthorized: onError("Wrong username or password.")
  - ConnectionFailed: onError("Cannot reach server — is it running?")
- `suspend fun sendMessage(to: String, text: String)`
  - ONLINE: enqueue + POST /send; failure → FLUSHING + flush
  - FLUSHING/OFFLINE: enqueue only
- `suspend fun logout()` — best-effort POST /logout; cancel sync; → LOGGED_OUT
- `suspend fun fetchInbox(): List<InboxEntry>` — GET /inbox; return emptyList() on error
- `suspend fun fetchConversation(with: String): List<ConversationMessage>` — GET /conversation
- `suspend fun markRead(fromUser: String)` — POST /mark-read

Sync loop (coroutine launched on login, every 3s):
- Poll GET /messages?since=lastServerTimestamp
- Update lastServerTimestamp
- For each message: skip if queue?.isDuplicate(msg.id) == true; else call onNewMessage
- On Unauthorized: → LOGGED_OUT; on ConnectionFailed: → OFFLINE

Flush loop (spec section 6 algorithm as coroutine):
- Pop nextPending, markSending, POST /send
  - 200: markSent; 401: markPending → LOGGED_OUT return; ConnectionFailed: markPending → OFFLINE return; 5xx: markFailed continue
- When queue empty: → ONLINE, restart sync (immediate poll)

Wire NetworkMonitor.onStatusChange to:
- true + OFFLINE: if queue has pending → FLUSHING+flush; else → ONLINE+sync
- false + ONLINE or FLUSHING: cancel sync → OFFLINE

---

### Main.kt
CLI entry point — `fun main(args: Array<String>)` with `runBlocking`:

Arg parsing: `--user <name>`, `--password <pass>`, `--server <url>` (default: http://localhost:8765)

Wire callbacks before auth:
- onNewMessage: handled based on current view (see below)
- onStateChange: "ONLINE" → print "✓ Connected"; "OFFLINE" → print "⚠ Offline"; "FLUSHING" → print "↑ Sending queued..."
- onError: print "✗ <reason>"

**Auth loop** (repeat until login succeeds):
- If --user and --password provided: call client.login(); exit(1) on false
- Otherwise: print "register or login?"; read username and password
  - register: client.register(); if true → client.login() with same creds
  - login: client.login()
  - On false: loop again

**Two view modes:**
Track: `var currentView = "inbox"`, `var openContact: String? = null`, `var myUsername = ""`

**printInbox(entries: List<InboxEntry>)**:
```
=== Inbox ===
  alice    3 unread
  bob      (no unread shown if 0)
open <user> | send <user> <msg> | quit
>
```

**printConversation(msgs: List<ConversationMessage>, contact: String)**:
```
=== alice ===
  [10:30]   alice: hi there
  [10:31]     you: hello!
─────────────────────────────────────
<message> | back | quit
>
```
- Timestamps: format Long epoch ms → local HH:mm using java.time.LocalDateTime
- Label: if fromUser == myUsername → "you" else contact name; pad to equal width

**Stdin read loop (inside runBlocking, use launch for sync callbacks):**

In inbox view:
- `open <user>` → markRead; fetch conversation; print; openContact=user; currentView="conversation"
- `send <user> <msg>` → client.sendMessage; refresh inbox
- `quit` → client.logout(); exitProcess(0)
- `offline`/`online` → hidden simulation commands

In conversation view:
- blank → skip
- `back` → currentView="inbox"; openContact=null; fetch+print inbox
- `quit` → client.logout(); exitProcess(0)
- `offline`/`online` → hidden simulation commands
- anything else → client.sendMessage(to=openContact, text=line); append message line to display

**onNewMessage** wiring (set callback after auth, inside runBlocking):
- In inbox view: launch { fetchInbox() then printInbox }
- In conversation view:
  - if msg.fromUser == openContact → print new message line + reprint prompt
  - else → print "[New message from <fromUser>]" + reprint prompt

Always reprint `> ` prompt after any output.

## Requirements
- No chat or messaging SDKs
- Must compile: `./gradlew compileKotlin` from clients/kotlin/
- Must run: `./gradlew run --args="--user bob --password secret"`

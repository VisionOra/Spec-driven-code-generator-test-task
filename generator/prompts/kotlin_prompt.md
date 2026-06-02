IMPORTANT: You are in pure text output mode. Do NOT use any tools. Do NOT write any files. Do NOT call Edit, Write, or Bash. Output ALL code as plain text in the exact format described below — nothing else.

You are generating a Kotlin JVM CLI messaging client. Implement the spec below exactly.

## Environment
- Kotlin 1.9+, JDK 17, Gradle (build.gradle already exists)
- HTTP: OkHttp 4.x — add to build.gradle: `implementation("com.squareup.okhttp3:okhttp:4.12.0")`
- JSON: kotlinx.serialization — add plugin and: `implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.0")`
- Local storage: exposed + sqlite-jdbc:
  `implementation("org.jetbrains.exposed:exposed-core:0.44.1")`
  `implementation("org.jetbrains.exposed:exposed-jdbc:0.44.1")`
  `implementation("org.xerial:sqlite-jdbc:3.44.1.0")`
- Async: Kotlin coroutines — `implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3")`
- Network detection for CLI: catch ConnectException as offline signal

## Spec
{{SPEC}}

## Output format
Each file must begin with exactly this line:
```kotlin
// filename: FileName.kt
```

## Files to generate

**Models.kt** — @Serializable data classes:
- `WireMessage`: id, from, to, text, timestamp, status
- `QueuedMessage`: localId, serverId (nullable), toUser, text, queuedAt, status (enum)
- `RegisterResponse`: userId, username
- `LoginResponse`: userId, username, sessionId
- `SendResponse`: id, timestamp
- `MessagesResponse`: messages, serverTimestamp
- `MessageStatus` enum: PENDING, SENDING, SENT, FAILED

**NetworkClient.kt** — OkHttp wrapper:
- All methods are suspend functions
- `suspend fun register(username: String, password: String, serverURL: String): RegisterResponse`
- `suspend fun login(username: String, password: String, serverURL: String): LoginResponse`
- `suspend fun send(to: String, text: String, sessionId: String, serverURL: String): SendResponse`
- `suspend fun getMessages(since: Long, sessionId: String, serverURL: String): MessagesResponse`
- `suspend fun logout(sessionId: String, serverURL: String)`
- Throw sealed class NetworkError: Unauthorized, UsernameTaken, ServerError, ConnectionFailed

**OfflineQueue.kt** — Exposed + SQLite:
- Database file: `~/.messaging-cli/queue.db`
- Define QueuedMessages table using Exposed DSL matching schema from spec
- `fun enqueue(to: String, text: String): String`
- `fun nextPending(): QueuedMessage?`
- `fun markSending(localId: String)`
- `fun markSent(localId: String, serverId: String)`
- `fun markFailed(localId: String)`
- `fun markPending(localId: String)`
- `fun isDuplicate(serverId: String): Boolean`

**NetworkMonitor.kt** — CLI connectivity simulation:
- `class NetworkMonitor`
- `var isOnline: Boolean = true`
- `fun setOffline()` / `fun setOnline()`
- `var onStatusChange: ((Boolean) -> Unit)? = null`

**MessageClient.kt** — state machine + coroutine orchestrator:
- Implement all 6 states as a sealed class or enum: LOGGED_OUT, REGISTERING, LOGGING_IN, ONLINE, FLUSHING, OFFLINE
- Sync loop: launch coroutine polling every 3 seconds when ONLINE
- Flush loop: run flushQueue algorithm from spec, as a coroutine
- `suspend fun register(username: String, password: String)`
- `suspend fun login(username: String, password: String)`
- `suspend fun sendMessage(to: String, text: String)`
- `suspend fun logout()`
- `var onMessageReceived: ((WireMessage) -> Unit)? = null`
- `var onStateChange: ((String) -> Unit)? = null`
- `var onError: ((String) -> Unit)? = null` — called with "username_taken" or "invalid_credentials"

**Main.kt** — CLI entry point:
- Args: `--user <name>`, `--password <pass>`, `--server <url>` (default: http://localhost:8765)
- If --user/--password not provided, prompt on stdin: ask "register or login?", then username, then password
- Read stdin in a loop after login
- Commands: `send <username> <message>`, `offline`, `online`, `quit`
- Print: `RECEIVED from <username>: <text>`, `STATE: <state>`, `ERROR: <reason>`
- Use `runBlocking` + coroutines

## Requirements
- No chat or messaging SDKs
- Handle java.net.ConnectException as ConnectionFailed (→ offline)
- Must run: `./gradlew run --args="--user bob --password secret"`

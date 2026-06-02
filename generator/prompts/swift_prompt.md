You are generating a Swift CLI messaging client. Write all source files directly to disk using your file tools.

Output directory: {{OUTPUT_DIR}}

Write every file listed below to that exact directory. Do not ask for permission — just write the files.

## Environment
- Swift 5.9+, macOS command-line executable (NOT an iOS app)
- Build system: Swift Package Manager (Package.swift already exists one level up — do NOT modify it)
- HTTP: URLSession (built-in)
- Local storage: SQLite.swift (already declared in Package.swift as dependency)
- Async: async/await
- Network detection: NWPathMonitor (Network framework, built-in)
- JSON: Codable (built-in)

## Spec
{{SPEC}}

## Files to write

Write each file to `{{OUTPUT_DIR}}/<FileName.swift>`.

**Models.swift**
- `WireMessage`: Codable, fields: id, from, to, text, timestamp (Int64), status
- `QueuedMessage`: Codable, fields: localId, serverId (String?), toUser, text, queuedAt (Int64), status (QueuedStatus enum)
- `QueuedStatus` enum: pending, sending, sent, failed — raw String values
- `RegisterResponse`: Codable, fields: userId, username
- `LoginResponse`: Codable, fields: userId, username, sessionId
- `SendResponse`: Codable, fields: id, timestamp (Int64)
- `MessagesResponse`: Codable, fields: messages ([WireMessage]), serverTimestamp (Int64)
- Note: `from` is a reserved word in Swift — use `CodingKeys` to map JSON key "from" to a Swift property named `fromUser`

**NetworkError.swift**
- `enum NetworkError: Error`: unauthorized, usernameTaken, serverError(Int), connectionFailed

**NetworkClient.swift** — URLSession wrapper (class NetworkClient):
- `func register(username: String, password: String, serverURL: String) async throws -> RegisterResponse`
- `func login(username: String, password: String, serverURL: String) async throws -> LoginResponse`
- `func send(to: String, text: String, sessionId: String, serverURL: String) async throws -> SendResponse`
- `func getMessages(since: Int64, sessionId: String, serverURL: String) async throws -> MessagesResponse`
- `func logout(sessionId: String, serverURL: String) async`
- All POST requests set `Content-Type: application/json`
- All authenticated requests set `X-Session-Id: <sessionId>` header
- HTTP 401 → throw `.unauthorized`; HTTP 409 → throw `.usernameTaken`; other 4xx/5xx → throw `.serverError(statusCode)`
- URLError.notConnectedToInternet → throw `.connectionFailed`

**OfflineQueue.swift** — SQLite.swift backed queue (class OfflineQueue):
- Open/create database at `~/.messaging-cli/queue.db`; create parent directory if needed
- Table schema exactly matching spec section 6
- `func enqueue(to: String, text: String) -> String` — returns localId (UUID)
- `func nextPending() -> QueuedMessage?`
- `func markSending(localId: String)`
- `func markSent(localId: String, serverId: String)`
- `func markFailed(localId: String)`
- `func markPending(localId: String)`
- `func isDuplicate(serverId: String) -> Bool`

**NetworkMonitor.swift** — NWPathMonitor wrapper (class NetworkMonitor):
- `var isOnline: Bool` (starts true)
- `var onStatusChange: ((Bool) -> Void)?`
- `func simulateOffline()` — sets isOnline=false, fires callback (for CLI --offline command)
- `func simulateOnline()` — sets isOnline=true, fires callback (for CLI --online command)
- Also start real NWPathMonitor; real path changes override simulated state

**MessageClient.swift** — state machine + orchestrator (actor MessageClient):
- States enum: loggedOut, registering, loggingIn, online, flushing, offline
- `var serverURL: String`
- `var onMessageReceived: ((WireMessage) -> Void)?`
- `var onStateChange: ((String) -> Void)?`
- `var onError: ((String) -> Void)?`
- `func register(username: String, password: String) async`
  - State: loggedOut → registering → loggedOut (success or error)
  - On 201: call onStateChange("loggedOut"), call onError("registered — please login")... actually just go back to loggedOut silently; caller handles
  - On usernameTaken: call onError("username_taken"); stay loggedOut
- `func login(username: String, password: String) async`
  - State: loggedOut → loggingIn → online (start sync loop) or loggedOut (on error)
  - On unauthorized: call onError("invalid_credentials")
- `func sendMessage(to: String, text: String) async`
  - When online: enqueue + immediate POST /send; on failure → flushing
  - When offline/flushing: enqueue only
- `func logout() async` — best-effort POST /logout; clear session; go loggedOut
- Sync loop: Task repeating every 3s when online; poll GET /messages
- Flush loop: implement flushQueue from spec exactly; when done → online
- On 401 from any request: clear session, go loggedOut
- On network error: go offline
- Wire up NetworkMonitor.onStatusChange to trigger state transitions

**main.swift** — CLI entry point:
- Parse args: `--user <name>`, `--password <pass>`, `--server <url>` (default: http://localhost:8765)
- If --user and --password not both provided: prompt interactively
  - Print "register or login? " → read line
  - Print "username: " → read line
  - Print "password: " → read line (use basic readLine, no echo suppression needed)
- Create MessageClient; wire callbacks:
  - onMessageReceived: print `RECEIVED from <username>: <text>`
  - onStateChange: print `STATE: <state>`
  - onError: print `ERROR: <reason>`
- If user provided --user and --password: call login directly (assume already registered)
- Otherwise: call register or login based on prompt
- After login, read loop on stdin:
  - `send <username> <rest of line>` → client.sendMessage
  - `offline` → networkMonitor.simulateOffline()
  - `online` → networkMonitor.simulateOnline()
  - `quit` → await client.logout(); exit(0)

## Requirements
- No chat or messaging SDKs
- No Combine, no SwiftUI
- Must compile with: `swift build` from the clients/swift directory
- Must run: `swift run messaging-cli --user alice --password secret`

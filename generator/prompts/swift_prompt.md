You are generating a Swift CLI messaging client. Implement the spec below exactly.

## Environment
- Swift 5.9+, macOS command-line executable (NOT an iOS app)
- Build system: Swift Package Manager — add dependencies to Package.swift
- HTTP: URLSession (built-in)
- Local storage: SQLite.swift — add to Package.swift:
  `.package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0")`
  and target dependency: `.product(name: "SQLite", package: "SQLite.swift")`
- Async: async/await
- Network detection: NWPathMonitor (Network framework, built-in)
- JSON: Codable (built-in)

## Spec
{{SPEC}}

## Output format
Each file must begin with exactly this line (so the harness can extract it):
```swift
// filename: FileName.swift
```

## Files to generate

**Models.swift** — Codable structs:
- `WireMessage`: id, from, to, text, timestamp, status
- `QueuedMessage`: localId, serverId (optional), toUser, text, queuedAt, status enum
- `LoginResponse`: userId, username, sessionId
- `SendResponse`: id, timestamp
- `MessagesResponse`: messages array, serverTimestamp

**NetworkClient.swift** — URLSession wrapper:
- `func login(username: String, serverURL: String) async throws -> LoginResponse`
- `func send(to: String, text: String, sessionId: String, serverURL: String) async throws -> SendResponse`
- `func getMessages(since: Int64, sessionId: String, serverURL: String) async throws -> MessagesResponse`
- `func logout(sessionId: String, serverURL: String) async`
- All requests set Content-Type: application/json and X-Session-Id header where required
- Throw a typed NetworkError (unauthorized, serverError, connectionFailed)

**OfflineQueue.swift** — SQLite.swift backed queue:
- Open/create database at `~/.messaging-cli/queue.db`
- Create queued_messages table with schema from spec
- `func enqueue(to: String, text: String) -> String` (returns localId)
- `func nextPending() -> QueuedMessage?`
- `func markSending(localId: String)`
- `func markSent(localId: String, serverId: String)`
- `func markFailed(localId: String)`
- `func markPending(localId: String)`
- `func isDuplicate(serverId: String) -> Bool`

**NetworkMonitor.swift** — NWPathMonitor wrapper:
- `class NetworkMonitor`
- `var isOnline: Bool`
- `var onStatusChange: ((Bool) -> Void)?`
- Start monitoring on init

**MessageClient.swift** — state machine + orchestrator:
- Implement all 5 states: loggedOut, loggingIn, online, flushing, offline
- Sync loop: poll every 3 seconds when online
- Flush loop: run flushQueue() algorithm from spec exactly
- On transition offline→online: immediate poll before waiting 3s
- `func login(username: String) async`
- `func sendMessage(to: String, text: String) async`
- `func logout() async`
- `var onMessageReceived: ((WireMessage) -> Void)?`
- `var onStateChange: ((String) -> Void)?`

**main.swift** — CLI entry point:
- Args: `--user <name>` (required), `--server <url>` (default: http://localhost:8765)
- After login, enter a read loop on stdin
- Commands:
  - `send <username> <message text>` — send a message
  - `offline` — simulate going offline (stop network calls, set isOnline=false)
  - `online` — simulate coming back online
  - `quit` — logout and exit
- Print received messages as: `RECEIVED from <username>: <text>`
- Print state changes as: `STATE: <state>`

## Requirements
- No chat or messaging SDKs
- No Combine, no SwiftUI
- All network calls must handle URLError.notConnectedToInternet as connectionFailed
- The binary must work: `swift run messaging-cli --user alice`

IMPORTANT: You are in pure text output mode with file-write tools available. Write all source files directly to disk using your file tools. Do not explain — just write the files.

Output directory: {{OUTPUT_DIR}}

You are generating a Swift CLI messaging client that implements the spec below.

## Environment
- Swift 5.9+, macOS command-line executable (NOT an iOS app)
- Build system: Swift Package Manager (Package.swift already exists — do NOT modify it)
- HTTP: URLSession (built-in)
- Local storage: SQLite.swift (already in Package.swift as `.product(name: "SQLite", package: "SQLite.swift")`)
- Async: async/await
- Network detection: NWPathMonitor (Network framework, built-in)
- JSON: Codable (built-in)

## Spec
{{SPEC}}

## Files to write

Write each file to `{{OUTPUT_DIR}}/<FileName.swift>`.

---

### Models.swift
Codable structs and enums:

```swift
// WireMessage — from server GET /messages
struct WireMessage: Codable {
    let id: String
    let fromUser: String   // JSON key "from"
    let to: String
    let text: String
    let timestamp: Int64
    let status: String
    enum CodingKeys: String, CodingKey {
        case id, to, text, timestamp, status
        case fromUser = "from"
    }
}

// QueuedMessage — local offline queue
enum QueuedStatus: String, Codable { case pending, sending, sent, failed }
struct QueuedMessage: Codable {
    let localId: String
    var serverId: String?
    let toUser: String
    let text: String
    let queuedAt: Int64
    var status: QueuedStatus
}

// Auth responses
struct RegisterResponse: Codable { let userId: String; let username: String }
struct LoginResponse: Codable { let userId: String; let username: String; let sessionId: String }

// Send / poll
struct SendResponse: Codable { let id: String; let timestamp: Int64 }
struct MessagesResponse: Codable { let messages: [WireMessage]; let serverTimestamp: Int64 }

// Inbox
struct InboxEntry: Codable { let contact: String; let unread: Int; let lastTimestamp: Int64 }
struct InboxResponse: Codable { let inbox: [InboxEntry] }

// Conversation
struct ConversationMessage: Codable {
    let id: String
    let fromUser: String   // JSON key "from_user"
    let toUser: String     // JSON key "to_user"
    let text: String
    let timestamp: Int64
    let read: Int
    enum CodingKeys: String, CodingKey {
        case id, text, timestamp, read
        case fromUser = "from_user"
        case toUser = "to_user"
    }
}
struct ConversationResponse: Codable { let messages: [ConversationMessage] }
```

---

### NetworkError.swift
```swift
enum NetworkError: Error {
    case unauthorized
    case usernameTaken
    case serverError(Int)
    case connectionFailed
}
```

---

### NetworkClient.swift
URLSession wrapper — class NetworkClient:

- `func register(username: String, password: String, serverURL: String) async throws -> RegisterResponse`
  POST /register — 409 → .usernameTaken, 401 → .unauthorized
- `func login(username: String, password: String, serverURL: String) async throws -> LoginResponse`
  POST /login — 401 → .unauthorized
- `func send(to: String, text: String, sessionId: String, serverURL: String) async throws -> SendResponse`
  POST /send
- `func getMessages(since: Int64, sessionId: String, serverURL: String) async throws -> MessagesResponse`
  GET /messages?since=<since>
- `func getInbox(sessionId: String, serverURL: String) async throws -> InboxResponse`
  GET /inbox
- `func getConversation(with other: String, sessionId: String, serverURL: String) async throws -> ConversationResponse`
  GET /conversation/<other>
- `func markRead(fromUser: String, sessionId: String, serverURL: String) async`
  POST /mark-read { "fromUser": fromUser } — best-effort, ignore errors
- `func logout(sessionId: String, serverURL: String) async`
  POST /logout — best-effort

Rules:
- All POST: Content-Type: application/json
- All authenticated: X-Session-Id header
- HTTP 401 → .unauthorized; HTTP 409 → .usernameTaken; other 4xx/5xx → .serverError(code)
- URLError.notConnectedToInternet and any connection error → .connectionFailed

---

### OfflineQueue.swift
SQLite.swift backed queue — class OfflineQueue:

- `init(username: String)` — DB path is `~/.messaging-cli/<username>/queue.db`
  Create parent directories if needed. This MUST be user-scoped: two users on the same
  machine must NOT share a queue DB or isDuplicate() will suppress incoming messages.
- Table schema from spec section 6 (local_id, server_id, to_user, text, queued_at, status)
- `func enqueue(to: String, text: String) -> String` — insert pending row, return localId UUID
- `func nextPending() -> QueuedMessage?` — oldest pending row
- `func markSending(localId: String)`
- `func markSent(localId: String, serverId: String)`
- `func markFailed(localId: String)`
- `func markPending(localId: String)`
- `func isDuplicate(serverId: String) -> Bool` — true if any row has server_id == serverId

---

### NetworkMonitor.swift
NWPathMonitor wrapper — class NetworkMonitor:

- `var isOnline: Bool` (starts true)
- `var onStatusChange: ((Bool) -> Void)?`
- Start real NWPathMonitor on init; path changes fire onStatusChange
- `func simulateOffline()` — force isOnline=false, fire callback (for test commands)
- `func simulateOnline()` — force isOnline=true, fire callback

---

### MessageClient.swift
Actor — actor MessageClient:

States:
```swift
enum State: String { case loggedOut, registering, loggingIn, online, flushing, offline }
```

Properties:
- `var serverURL: String`
- `var onNewMessage: ((WireMessage) -> Void)?`   // fires from sync loop
- `var onStateChange: ((String) -> Void)?`
- `var onError: ((String) -> Void)?`
- `let networkMonitor = NetworkMonitor()`
- private: network, queue (Optional, set after login), sessionId, currentUser, lastServerTimestamp, syncTask

Methods:
- `func setupNetworkMonitor()` — wire networkMonitor.onStatusChange → handleNetworkChange
- `func setCallbacks(onNewMessage:, onStateChange:, onError:)`
- `func register(username: String, password: String) async -> Bool`
  - loggedOut → registering → loggedOut (returns true)
  - On usernameTaken: onError("That username is already taken."); return false
  - On connectionFailed: onError("Cannot reach server — is it running?"); return false
- `func login(username: String, password: String) async -> Bool`
  - loggedOut → loggingIn → online (create OfflineQueue(username:), start sync loop; returns true)
  - On unauthorized: onError("Wrong username or password."); return false
  - On connectionFailed: onError("Cannot reach server — is it running?"); return false
- `func sendMessage(to: String, text: String) async`
  - online: enqueue + POST /send; on failure → flushing
  - flushing/offline: enqueue only
- `func logout() async` — best-effort POST /logout; clear session/queue; → loggedOut
- `func fetchInbox() async -> [InboxEntry]` — GET /inbox; returns [] on error
- `func fetchConversation(with: String) async -> [ConversationMessage]` — GET /conversation/<user>; returns [] on error
- `func markRead(fromUser: String) async` — POST /mark-read

Sync loop (Task, runs every 3s when online):
- Poll GET /messages?since=lastServerTimestamp
- Update lastServerTimestamp
- For each message: skip if queue?.isDuplicate(serverId: msg.id) == true; else call onNewMessage
- On unauthorized: → loggedOut; on connectionFailed: → offline

Flush loop (spec section 6 algorithm exactly):
- While state == flushing: pop nextPending, markSending, POST /send
  - 200: markSent; 401: markPending → loggedOut; connectionFailed: markPending → offline; 5xx: markFailed continue
- When queue empty: → online, restart sync loop (immediate poll)

Network change handler:
- online event + state==offline: if queue has pending → flushing+flush; else → online+sync
- offline event + state==online or flushing: cancel sync, → offline

---

### main.swift
CLI entry point — async main:

Arg parsing: `--user <name>`, `--password <pass>`, `--server <url>` (default: http://localhost:8765)

**Read stdin on a DispatchQueue background thread** to avoid blocking the cooperative thread pool
(which would starve the sync Task). Use this pattern:
```swift
func nextLine() async -> String? {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInteractive).async {
            cont.resume(returning: readLine())
        }
    }
}
```

**Auth loop** (repeats until successful login):
- If --user and --password both provided: call client.login() directly; exit(1) on failure
- Otherwise: loop asking "register or login?", username, password
  - register: call client.register(); if true → auto-call client.login() with same creds
  - login: call client.login()
  - On false (error already printed via onError): loop back and ask again

**Two view modes after login:**

Track: `var currentView = "inbox"`, `var openContact: String? = nil`

**Inbox view** — printed by `func printInbox(_ entries: [InboxEntry])`:
```
=== Inbox ===
  alice    3 unread
  bob      0 unread
open <user> | send <user> <msg> | quit
>
```
- Left-pad contact names to equal width; show "unread" count or blank if 0
- Call `printInbox(await client.fetchInbox())` immediately after login and after `back`

**Conversation view** — printed by `func printConversation(_ msgs: [ConversationMessage], with contact: String, myUsername: String)`:
```
=== alice ===
  [10:30]   alice: hi there
  [10:31]     you: hello!
─────────────────────────────────────
<message> | back | quit
>
```
- Timestamps: format Int64 ms epoch → local HH:MM using DateFormatter
- Label: if fromUser == myUsername → "you", else contact name
- Pad label to fixed width (max(len("you"), len(contact))) for alignment

**Command parsing in the read loop (while let line = await nextLine()):**

In inbox view:
- `open <user>` → openContact=user; currentView="conversation"; markRead; fetch+print conversation
- `send <user> <msg>` → client.sendMessage(to: user, text: msg); refresh inbox
- `quit` → logout; exit(0)
- `offline`/`online` → hidden simulation commands

In conversation view:
- empty/whitespace → skip
- `back` → currentView="inbox"; openContact=nil; fetch+print inbox
- `quit` → logout; exit(0)
- `offline`/`online` → hidden simulation commands
- anything else → treat as message to send to openContact; client.sendMessage; append to display

**onNewMessage callback:**
- In inbox view: fetch+print inbox (refresh unread counts)
- In conversation view:
  - if msg.fromUser == openContact → print the new message line + reprint prompt
  - else → print "[New message from <msg.fromUser>]" + reprint prompt

**onStateChange callback:**
- "online" → print "✓ Connected"
- "offline" → print "⚠ Offline — messages will be queued"
- "flushing" → print "↑ Sending queued messages..."
- others → silent

**onError callback:** print "✗ <reason>"

Always reprint `> ` prompt after any output.

## Requirements
- No chat or messaging SDKs; no Combine; no SwiftUI
- Must compile: `swift build` from clients/swift/
- Must run: `swift run messaging-cli --user alice --password secret`

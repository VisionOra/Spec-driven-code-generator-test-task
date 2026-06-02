# Messaging Protocol Specification v1.0

## 1. Transport

All communication is HTTP/1.1. No WebSocket. No long-polling.
Server base URL: http://localhost:8765 (configurable via --server flag)
Authentication: every request except /login carries header `X-Session-Id: <sessionId>`

---

## 2. API Endpoints

### POST /register
Request:
  { "username": "alice", "password": "secret" }
Response 201:
  { "userId": "uuid", "username": "alice" }
Response 409:
  { "error": "username_taken" }
Notes:
  - Username must be unique. On 409, client shows error and prompts for a different name.
  - Password is bcrypt-hashed server-side; plaintext is never stored.

### POST /login
Request:
  { "username": "alice", "password": "secret" }
Response 200:
  { "userId": "uuid", "username": "alice", "sessionId": "uuid" }
Response 401:
  { "error": "invalid_credentials" }
Notes:
  - Returns the same 401 for unknown username and wrong password (no enumeration).
  - Re-login invalidates the previous session and issues a new sessionId.
  - Client stores sessionId in memory for the session lifetime.

### POST /send
Header: X-Session-Id: <sessionId>
Request:
  { "to": "bob", "text": "Hi Bob" }
Response 200:
  { "id": "uuid", "timestamp": 1234567890000 }
Response 401:
  { "error": "unauthorized" }

### GET /messages?since=<timestamp>
Header: X-Session-Id: <sessionId>
Response 200:
  {
    "messages": [
      { "id": "uuid", "from": "alice", "to": "bob",
        "text": "Hi Bob", "timestamp": 1234567890000, "status": "delivered" }
    ],
    "serverTimestamp": 1234567890123
  }
Response 401:
  { "error": "unauthorized" }
Notes:
  - since=0 returns all messages for this user.
  - Client MUST store serverTimestamp from each response and use it as since= next call.

### POST /logout
Header: X-Session-Id: <sessionId>
Response 200: {}
Notes: Best-effort. Client clears session regardless of response.

---

## 3. Data Models

### Wire Message (what server sends/receives)
```json
{
  "id":        "server-generated UUID",
  "from":      "username",
  "to":        "username",
  "text":      "string, max 4096 UTF-8 bytes",
  "timestamp": "int64 milliseconds since epoch",
  "status":    "delivered"
}
```

### QueuedMessage (client local storage only)
```json
{
  "localId":  "client-generated UUID — primary key in local db",
  "serverId": "null until POST /send succeeds, then set from response id",
  "toUser":   "username",
  "text":     "string",
  "queuedAt": "int64 milliseconds, client-set at queue time",
  "status":   "pending | sending | sent | failed"
}
```

The localId/serverId split is mandatory. Client assigns localId at queue time.
Server-assigned id is stored in serverId only after ACK.

---

## 4. Client States

```
LOGGED_OUT   — no session
REGISTERING  — POST /register in flight
LOGGING_IN   — POST /login in flight
ONLINE       — session active, sync loop running every 3 seconds
FLUSHING     — session active, draining offline queue
OFFLINE      — session saved, no network
```

---

## 5. State Transitions

```
LOGGED_OUT   + register()             → REGISTERING
REGISTERING  + 201 response           → LOGGED_OUT (prompt user to now login)
REGISTERING  + 409 username_taken     → LOGGED_OUT (surface error: pick another username)
REGISTERING  + network error          → LOGGED_OUT (surface error: try again)
LOGGED_OUT   + login()                → LOGGING_IN
LOGGING_IN   + 200 response           → ONLINE (start sync loop)
LOGGING_IN   + 401 invalid_creds      → LOGGED_OUT (surface error: wrong username/password)
LOGGING_IN   + network error          → LOGGED_OUT (surface error: try again)
ONLINE       + network lost           → OFFLINE (stop sync loop)
ONLINE       + user sends message     → ONLINE (queue + immediate POST /send)
ONLINE       + POST /send fails       → FLUSHING (message stays pending in queue)
FLUSHING     + queue drained          → ONLINE (restart sync loop)
FLUSHING     + network lost           → OFFLINE
FLUSHING     + user sends message     → FLUSHING (append to queue tail — no second flush)
OFFLINE      + network restored       → FLUSHING (if queue non-empty) or ONLINE
OFFLINE      + user sends message     → OFFLINE (queue locally, status=pending)
ANY          + 401 response           → LOGGED_OUT (keep queue, clear sessionId)
ONLINE       + logout()               → LOGGED_OUT (POST /logout best-effort)
```

---

## 6. Offline Queue

### Local Database Schema
```sql
CREATE TABLE queued_messages (
  local_id   TEXT PRIMARY KEY,
  server_id  TEXT,
  to_user    TEXT NOT NULL,
  text       TEXT NOT NULL,
  queued_at  INTEGER NOT NULL,
  status     TEXT NOT NULL DEFAULT 'pending'
);
```

### Flush Algorithm (identical on all platforms)
```
function flushQueue():
  while true:
    msg = SELECT * FROM queued_messages
          WHERE status = 'pending'
          ORDER BY queued_at ASC
          LIMIT 1
    if msg is null: break  -- queue empty

    UPDATE queued_messages SET status = 'sending' WHERE local_id = msg.local_id

    result = POST /send { to: msg.to_user, text: msg.text }

    if result == 200:
      UPDATE queued_messages SET status = 'sent', server_id = result.id
      WHERE local_id = msg.local_id

    else if result == 401:
      UPDATE queued_messages SET status = 'pending' WHERE local_id = msg.local_id
      transition to LOGGED_OUT
      return

    else if network error or timeout:
      UPDATE queued_messages SET status = 'pending' WHERE local_id = msg.local_id
      transition to OFFLINE
      return

    else (5xx):
      UPDATE queued_messages SET status = 'failed' WHERE local_id = msg.local_id
      -- log and continue to next message
```

### Deduplication on Receive
When GET /messages returns a message, check if its id matches any server_id
in the local queue. If match found, skip — already sent by this client.

---

## 7. Sync Loop
- When ONLINE: poll GET /messages?since=<lastServerTimestamp> every 3 seconds
- On transition OFFLINE → ONLINE or FLUSHING → ONLINE: immediate poll (no 3s wait)
- Store serverTimestamp from each response as lastServerTimestamp
- First launch: use since=0

---

## 8. Network Detection

### Swift (iOS/macOS)
```swift
import Network
let monitor = NWPathMonitor()
monitor.pathUpdateHandler = { path in
    if path.status == .satisfied { /* → online */ }
    else                         { /* → offline */ }
}
monitor.start(queue: .global())
```

### Kotlin (Android/JVM)
For CLI/JVM targets: attempt HTTP request; if connection refused → offline.
For Android: use ConnectivityManager.registerDefaultNetworkCallback.

### CLI simulation (both clients)
Accept --offline and --online commands on stdin to simulate connectivity changes.

---

## 9. Error Handling

| Condition                    | Required Action                                  |
|------------------------------|--------------------------------------------------|
| 401 on any request           | Clear sessionId, keep queue, go to LOGGED_OUT    |
| 5xx on POST /send            | Mark message failed, continue flush loop         |
| Network error / timeout      | Go OFFLINE, all pending stays queued             |
| 400 on POST /send            | Mark message failed, do not retry (client bug)   |

---

## 10. Behavioral Test Scenarios

### Scenario A: Basic send/receive
1. Alice logs in
2. Bob logs in
3. Alice sends "Hi Bob" to bob
4. Bob polls → receives message from alice
PASS: message appears, from=alice, text="Hi Bob"

### Scenario B: Offline queue FIFO
1. Alice logs in
2. Alice goes offline
3. Alice sends "Message 1" and "Message 2"
4. Bob polls → receives nothing (Alice is offline)
5. Alice goes online
6. Flush runs → both messages sent in order
7. Bob polls → receives Message 1, then Message 2
PASS: both received, Message 1 before Message 2

### Scenario C: Full Alice/Bob cross-platform
1.  Alice (Swift) logs in; Bob (Kotlin) logs in
2.  Alice sends "Hi Bob, I have something important to tell you"
3.  Bob polls → receives Alice's message
4.  Bob sends "What is it?"
5.  Alice polls → receives Bob's message
6.  Alice goes offline
7.  Alice sends "It's about our trip" → queued
8.  Bob goes offline
9.  Bob sends "I'm waiting" → queued
10. Alice goes online → flushes "It's about our trip"
11. Alice goes offline
12. Bob goes online → receives "It's about our trip", flushes "I'm waiting"
13. Alice goes online → receives "I'm waiting"
PASS: all messages delivered in order, no duplicates

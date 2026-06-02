# Spec-Driven Messaging Code Generator — Execution Plan

---

## What You're Building

- **Python server** — minimal FastAPI, in-memory, hand-written
- **Swift CLI client** — macOS terminal binary, generated from spec
- **Kotlin JVM client** — terminal binary, generated from spec
- **Generator harness** — Python script that calls Claude Code and compile-checks output
- **Spec** — single Markdown file that drives both clients

---

## Step 0: Environment Check (do this first, before anything else)

```bash
claude --version          # must print a version
swift --version           # Swift 5.9+
kotlinc -version          # Kotlin 1.9+
python3 --version         # 3.11+
java -version             # JDK 17+

# Verify Claude Code non-interactive mode works
echo "Write hello world in Python" | claude --print
# Must print Python code, not hang interactively
```

If `claude --print` hangs or errors, stop and fix it. Everything else depends on this.

---

## Step 1: Repository Structure

```bash
mkdir messaging-generator && cd messaging-generator
git init

mkdir -p spec
mkdir -p generator/prompts
mkdir -p server
mkdir -p clients/swift/Sources/messaging-cli
mkdir -p clients/kotlin/app/src/main/kotlin/com/messaging
mkdir -p tests

touch README.md DESIGN.md AGENTS.md FUTURE.md
git add . && git commit -m "feat: initial project structure"
```

---

## Step 2: Python Server

### Auth design decisions (read before coding)

**Registration vs login are separate operations:**
- `POST /register` — creates a new account. Returns 409 if username already taken.
- `POST /login` — authenticates an existing account with password. Returns 401 if wrong credentials.

**Password storage:** hash with `bcrypt` (never store plaintext). Use `passlib[bcrypt]`.

**Duplicate username:** registration returns HTTP 409 Conflict with `{"error": "username_taken"}`. Clients must surface this to the user and prompt for a different name.

**Wrong password at login:** returns HTTP 401 with `{"error": "invalid_credentials"}`. Do NOT distinguish "user not found" from "wrong password" — same error for both (prevents username enumeration).

**Session:** unchanged — UUID token in `X-Session-Id` header for all post-auth requests.

---

### `server/requirements.txt`
```
fastapi
uvicorn
passlib[bcrypt]
```

### `server/store.py`
```python
import threading, uuid, time
from passlib.context import CryptContext

pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")

class Store:
    def __init__(self):
        self._lock = threading.Lock()
        self._users = {}     # username → {userId, username, passwordHash, sessionId}
        self._sessions = {}  # sessionId → username
        self._messages = []  # append-only

    def register(self, username: str, password: str) -> dict:
        """Returns user dict or raises ValueError('username_taken')."""
        with self._lock:
            if username in self._users:
                raise ValueError("username_taken")
            user_id = str(uuid.uuid4())
            self._users[username] = {
                "userId": user_id,
                "username": username,
                "passwordHash": pwd_ctx.hash(password),
                "sessionId": None,
            }
            return {"userId": user_id, "username": username}

    def login(self, username: str, password: str) -> dict:
        """Returns {userId, username, sessionId} or raises ValueError('invalid_credentials')."""
        with self._lock:
            user = self._users.get(username)
            if not user or not pwd_ctx.verify(password, user["passwordHash"]):
                raise ValueError("invalid_credentials")
            # Invalidate old session
            if user["sessionId"]:
                self._sessions.pop(user["sessionId"], None)
            session_id = str(uuid.uuid4())
            user["sessionId"] = session_id
            self._sessions[session_id] = username
            return {"userId": user["userId"], "username": username, "sessionId": session_id}

    def get_user_by_session(self, session_id: str) -> str | None:
        return self._sessions.get(session_id)

    def send_message(self, from_user: str, to: str, text: str) -> dict:
        with self._lock:
            msg = {
                "id": str(uuid.uuid4()),
                "from": from_user,
                "to": to,
                "text": text,
                "timestamp": int(time.time() * 1000),
                "status": "delivered"
            }
            self._messages.append(msg)
            return msg

    def get_messages(self, for_user: str, since: int = 0) -> list:
        with self._lock:
            return [m for m in self._messages
                    if m["to"] == for_user and m["timestamp"] > since]

store = Store()
```

### `server/main.py`
```python
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from store import store

app = FastAPI()

class RegisterRequest(BaseModel):
    username: str
    password: str

class LoginRequest(BaseModel):
    username: str
    password: str

class SendRequest(BaseModel):
    to: str
    text: str

def auth(session_id: str | None) -> str:
    if not session_id:
        raise HTTPException(401, "Missing X-Session-Id header")
    user = store.get_user_by_session(session_id)
    if not user:
        raise HTTPException(401, "Invalid session")
    return user

@app.post("/register", status_code=201)
def register(req: RegisterRequest):
    try:
        return store.register(req.username, req.password)
    except ValueError as e:
        if str(e) == "username_taken":
            raise HTTPException(409, {"error": "username_taken"})
        raise

@app.post("/login")
def login(req: LoginRequest):
    try:
        return store.login(req.username, req.password)
    except ValueError:
        raise HTTPException(401, {"error": "invalid_credentials"})

@app.post("/send")
def send(req: SendRequest, x_session_id: str | None = Header(None)):
    username = auth(x_session_id)
    return store.send_message(username, req.to, req.text)

@app.get("/messages")
def messages(since: int = 0, x_session_id: str | None = Header(None)):
    username = auth(x_session_id)
    msgs = store.get_messages(username, since)
    server_ts = int(__import__("time").time() * 1000)
    return {"messages": msgs, "serverTimestamp": server_ts}

@app.post("/logout")
def logout(x_session_id: str | None = Header(None)):
    auth(x_session_id)
    return {}
```

### Smoke test
```bash
cd server && pip3 install -r requirements.txt
python3 -m uvicorn main:app --port 8765 &

# Register alice (201)
curl -s -X POST localhost:8765/register \
  -H "Content-Type: application/json" -d '{"username":"alice","password":"secret"}'

# Register alice again → 409 username_taken
curl -s -X POST localhost:8765/register \
  -H "Content-Type: application/json" -d '{"username":"alice","password":"other"}'

# Login with wrong password → 401
curl -s -X POST localhost:8765/login \
  -H "Content-Type: application/json" -d '{"username":"alice","password":"wrong"}'

# Login correctly (copy sessionId)
SESSION=$(curl -s -X POST localhost:8765/login \
  -H "Content-Type: application/json" -d '{"username":"alice","password":"secret"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['sessionId'])")

curl -s -X POST localhost:8765/send \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: $SESSION" \
  -d '{"to":"bob","text":"hello"}'

curl -s "localhost:8765/messages?since=0" -H "X-Session-Id: $SESSION"
```

```bash
git add server/ && git commit -m "feat: add Python server with in-memory store"
```

---

## Step 3: The Spec

### `spec/protocol-spec.md`

```markdown
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
  - Username must be unique. Client must show an error and let the user pick another.
  - Password is validated on the server; plaintext is never stored (bcrypt hashed).

### POST /login
Request:
  { "username": "alice", "password": "secret" }
Response 200:
  { "userId": "uuid", "username": "alice", "sessionId": "uuid" }
Response 401:
  { "error": "invalid_credentials" }
Notes:
  - Returns the same 401 for "user not found" and "wrong password" (no enumeration).
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
REGISTERING  + 201 response           → LOGGED_OUT (prompt user to login)
REGISTERING  + 409 username_taken     → LOGGED_OUT (show error: pick another username)
REGISTERING  + network error          → LOGGED_OUT (show error: try again)
LOGGED_OUT   + login()                → LOGGING_IN
LOGGING_IN   + 200 response           → ONLINE (start sync loop)
LOGGING_IN   + 401 invalid_creds      → LOGGED_OUT (show error: wrong username/password)
LOGGING_IN   + network error          → LOGGED_OUT (show error: try again)
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
1. Alice registers (201)
2. Bob registers (201)
3. Alice logs in → session
4. Bob logs in → session
5. Alice sends "Hi Bob" to bob
6. Bob polls → receives message from alice
PASS: message appears, from=alice, text="Hi Bob"

### Scenario A2: Duplicate username rejected
1. Alice registers with username "alice" (201)
2. Alice tries to register again with same username → 409
PASS: second registration returns username_taken error

### Scenario A3: Wrong password rejected
1. Alice registers (201)
2. Alice logs in with wrong password → 401 invalid_credentials
PASS: login fails with correct error

### Scenario B: Offline queue FIFO
1. Alice registers + logs in
2. Alice goes offline
3. Alice sends "Message 1" and "Message 2"
4. Bob polls → receives nothing (Alice is offline)
5. Alice goes online
6. Flush runs → both messages sent in order
7. Bob polls → receives Message 1, then Message 2
PASS: both received, Message 1 before Message 2

### Scenario C: Full Alice/Bob cross-platform
1.  Alice (Swift) registers + logs in; Bob (Kotlin) registers + logs in
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
```

```bash
git add spec/ && git commit -m "feat: add messaging protocol spec v1.0"
```

---

## Step 4: Generator Harness

### `generator/generate.py`
```python
#!/usr/bin/env python3
"""
Usage:
  python generator/generate.py --lang swift  --output clients/swift/Sources/messaging-cli/
  python generator/generate.py --lang kotlin --output clients/kotlin/app/src/main/kotlin/com/messaging/
"""
import argparse, subprocess, sys, re
from pathlib import Path

SPEC      = Path("spec/protocol-spec.md")
PROMPTS   = Path("generator/prompts")
MAX_RETRY = 2

def build_prompt(lang: str, spec: str, errors: str = "") -> str:
    template = (PROMPTS / f"{lang}_prompt.md").read_text()
    prompt = template.replace("{{SPEC}}", spec)
    if errors:
        prompt += f"\n\n## COMPILATION ERRORS — fix these\n```\n{errors[:1500]}\n```\nRegenerate all files with fixes applied."
    return prompt

def call_claude(prompt: str) -> str:
    result = subprocess.run(
        ["claude", "--print"],
        input=prompt, capture_output=True, text=True, timeout=300
    )
    if result.returncode != 0:
        print(f"Claude error:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout

def extract_files(output: str) -> dict[str, str]:
    # Matches: ```swift\n// filename: Foo.swift\ncontent\n```
    pattern = r'```(?:swift|kotlin)\n// filename: ([^\n]+)\n(.*?)```'
    files = {}
    for m in re.finditer(pattern, output, re.DOTALL):
        files[m.group(1).strip()] = m.group(2)
    return files

def write_files(files: dict[str, str], out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        header = f"// GENERATED — regenerate: python generator/generate.py --lang {'swift' if name.endswith('.swift') else 'kotlin'} --output {out_dir}\n"
        (out_dir / name).write_text(header + content)
        print(f"  wrote {out_dir / name}")

def compile_check(lang: str, root: Path) -> tuple[bool, str]:
    if lang == "swift":
        r = subprocess.run(["swift", "build"], cwd=root.parents[2],
                           capture_output=True, text=True)
    else:
        r = subprocess.run(["./gradlew", "compileKotlin"], cwd=root.parents[3],
                           capture_output=True, text=True)
    return r.returncode == 0, r.stderr + r.stdout

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang",   required=True, choices=["swift", "kotlin"])
    ap.add_argument("--output", required=True, type=Path)
    args = ap.parse_args()

    spec   = SPEC.read_text()
    errors = ""

    for attempt in range(1, MAX_RETRY + 1):
        print(f"[{args.lang}] attempt {attempt}/{MAX_RETRY}...")
        output = call_claude(build_prompt(args.lang, spec, errors))
        files  = extract_files(output)

        if not files:
            print("No files extracted — check prompt output format", file=sys.stderr)
            print(output[:500])
            sys.exit(1)

        write_files(files, args.output)
        ok, errors = compile_check(args.lang, args.output)

        if ok:
            print(f"[{args.lang}] ✓ compiled successfully")
            return

        print(f"[{args.lang}] compile failed:\n{errors[:300]}")

    print(f"[{args.lang}] failed after {MAX_RETRY} attempts — fix prompts and retry")
    sys.exit(1)

if __name__ == "__main__":
    main()
```

```bash
git add generator/generate.py
git commit -m "feat: add generator harness with compile-check retry loop"
```

---

## Step 5: Prompt Templates

### `generator/prompts/swift_prompt.md`

````markdown
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
- `RegisterResponse`: userId, username
- `LoginResponse`: userId, username, sessionId
- `SendResponse`: id, timestamp
- `MessagesResponse`: messages array, serverTimestamp

**NetworkClient.swift** — URLSession wrapper:
- `func register(username: String, password: String, serverURL: String) async throws -> RegisterResponse`
- `func login(username: String, password: String, serverURL: String) async throws -> LoginResponse`
- `func send(to: String, text: String, sessionId: String, serverURL: String) async throws -> SendResponse`
- `func getMessages(since: Int64, sessionId: String, serverURL: String) async throws -> MessagesResponse`
- `func logout(sessionId: String, serverURL: String) async`
- All requests set Content-Type: application/json and X-Session-Id header where required
- Throw a typed NetworkError (unauthorized, usernameTaken, serverError, connectionFailed)

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
- Implement all 6 states: loggedOut, registering, loggingIn, online, flushing, offline
- Sync loop: poll every 3 seconds when online
- Flush loop: run flushQueue() algorithm from spec exactly
- On transition offline→online: immediate poll before waiting 3s
- `func register(username: String, password: String) async`
- `func login(username: String, password: String) async`
- `func sendMessage(to: String, text: String) async`
- `func logout() async`
- `var onMessageReceived: ((WireMessage) -> Void)?`
- `var onStateChange: ((String) -> Void)?`
- `var onError: ((String) -> Void)?` — surface username_taken, invalid_credentials to UI

**main.swift** — CLI entry point:
- Args: `--user <name>`, `--password <pass>`, `--server <url>` (default: http://localhost:8765)
- If `--user` and `--password` not given, prompt interactively on stdin
- First prompt: `register` or `login`? Then ask username + password
- Commands after login:
  - `send <username> <message text>` — send a message
  - `offline` — simulate going offline
  - `online` — simulate coming back online
  - `quit` — logout and exit
- Print received messages as: `RECEIVED from <username>: <text>`
- Print state changes as: `STATE: <state>`
- Print errors as: `ERROR: <reason>` (e.g. username_taken, invalid_credentials)

## Requirements
- No chat or messaging SDKs
- No Combine, no SwiftUI
- All network calls must handle URLError.notConnectedToInternet as connectionFailed
- The binary must work: `swift run messaging-cli --user alice --password secret`
````

### `generator/prompts/kotlin_prompt.md`

````markdown
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
- `var onError: ((String) -> Unit)? = null` — surface username_taken, invalid_credentials

**Main.kt** — CLI entry point:
- Args: `--user <name>`, `--password <pass>`, `--server <url>` (default: http://localhost:8765)
- If args not provided, prompt interactively: `register` or `login`? then username + password
- Read stdin in a loop after login
- Commands: `send <username> <message>`, `offline`, `online`, `quit`
- Print: `RECEIVED from <username>: <text>`, `STATE: <state>`, `ERROR: <reason>`
- Use `runBlocking` + coroutines

## Requirements
- No chat or messaging SDKs
- Handle java.net.ConnectException as ConnectionFailed (→ offline)
- Must run: `./gradlew run --args="--user bob --password secret"`
````

```bash
git add generator/prompts/
git commit -m "feat: add Swift and Kotlin generation prompt templates"
```

---

## Step 6: Client Build Scaffolding (hand-written, not generated)

### `clients/swift/Package.swift`
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "messaging-cli",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0")
    ],
    targets: [
        .executableTarget(
            name: "messaging-cli",
            dependencies: [.product(name: "SQLite", package: "SQLite.swift")],
            path: "Sources/messaging-cli"
        )
    ]
)
```

### `clients/kotlin/settings.gradle`
```groovy
rootProject.name = "messaging-cli"
```

### `clients/kotlin/build.gradle`
```groovy
plugins {
    id 'org.jetbrains.kotlin.jvm' version '1.9.22'
    id 'org.jetbrains.kotlin.plugin.serialization' version '1.9.22'
    id 'application'
}

group = 'com.messaging'
version = '1.0'

repositories {
    mavenCentral()
}

dependencies {
    implementation 'com.squareup.okhttp3:okhttp:4.12.0'
    implementation 'org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.0'
    implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3'
    implementation 'org.jetbrains.exposed:exposed-core:0.44.1'
    implementation 'org.jetbrains.exposed:exposed-jdbc:0.44.1'
    implementation 'org.xerial:sqlite-jdbc:3.44.1.0'
}

application {
    mainClass = 'com.messaging.MainKt'
}
```

```bash
git add clients/
git commit -m "feat: add Swift and Kotlin build scaffolding"
```

---

## Step 7: Generate the Clients

```bash
# Generate Swift client
python generator/generate.py \
  --lang swift \
  --output clients/swift/Sources/messaging-cli/

# Generate Kotlin client
python generator/generate.py \
  --lang kotlin \
  --output clients/kotlin/app/src/main/kotlin/com/messaging/
```

The harness will:
1. Inject spec into the prompt template
2. Call `claude --print` 
3. Parse output files and write them
4. Run `swift build` or `./gradlew compileKotlin`
5. If compile errors: re-prompt with error text and retry once

```bash
git add clients/
git commit -m "feat: generate Swift and Kotlin CLI clients"
```

---

## Step 8: Smoke Test Both Clients

```bash
# Server must be running
cd server && uvicorn main:app --port 8765

# Test Swift
cd clients/swift
swift run messaging-cli --user alice
# Should print: STATE: online
# Type: send bob hello
# Should print: STATE: online (message sent)

# Test Kotlin
cd clients/kotlin
./gradlew run --args="--user bob"
# Should print: STATE: online
# Within 3 seconds: RECEIVED from alice: hello
```

If either fails to compile or connect, inspect the error, adjust the relevant prompt template, and re-run the generator.

```bash
git add .
git commit -m "fix: update prompts based on smoke test findings"
# (only if you had to change prompts)
```

---

## Step 9: Integration Tests

### `tests/integration_test.py`
```python
import subprocess, time, threading, sys
from pathlib import Path

SERVER_URL = "http://localhost:8765"

class CLIClient:
    def __init__(self, lang: str, username: str):
        if lang == "swift":
            cmd = ["swift", "run", "messaging-cli",
                   "--user", username, "--server", SERVER_URL]
            cwd = Path("clients/swift")
        else:
            cmd = ["./gradlew", "run",
                   "--args", f"--user {username} --server {SERVER_URL}"]
            cwd = Path("clients/kotlin")

        self.username = username
        self.received = []
        self.states   = []
        self.proc = subprocess.Popen(
            cmd, cwd=cwd,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1
        )
        threading.Thread(target=self._read, daemon=True).start()
        time.sleep(5)  # wait for login + first poll

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if "RECEIVED" in line:
                self.received.append(line)
            if "STATE:" in line:
                self.states.append(line)

    def send(self, to: str, text: str):
        self.proc.stdin.write(f"send {to} {text}\n")
        self.proc.stdin.flush()

    def go_offline(self):
        self.proc.stdin.write("offline\n")
        self.proc.stdin.flush()
        time.sleep(0.5)

    def go_online(self):
        self.proc.stdin.write("online\n")
        self.proc.stdin.flush()
        time.sleep(0.5)

    def wait_for(self, text: str, timeout: int = 12) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if any(text in m for m in self.received):
                return True
            time.sleep(0.3)
        return False

    def stop(self):
        try:
            self.proc.stdin.write("quit\n")
            self.proc.stdin.flush()
        except:
            pass
        self.proc.terminate()


def scenario_a():
    print("--- Scenario A: Basic send/receive ---")
    alice = CLIClient("swift",  "alice_a")
    bob   = CLIClient("kotlin", "bob_a")

    alice.send("bob_a", "Hi Bob")
    assert bob.wait_for("Hi Bob"), "FAIL: Bob did not receive Alice's message"

    alice.stop(); bob.stop()
    print("PASS\n")


def scenario_b():
    print("--- Scenario B: Offline queue FIFO ---")
    alice = CLIClient("swift",  "alice_b")
    bob   = CLIClient("kotlin", "bob_b")

    alice.go_offline()
    alice.send("bob_b", "Message 1")
    alice.send("bob_b", "Message 2")
    time.sleep(2)

    assert not bob.wait_for("Message 1", timeout=3), \
        "FAIL: Message arrived while Alice was offline"

    alice.go_online()
    assert bob.wait_for("Message 1", timeout=12), "FAIL: Message 1 not delivered"
    assert bob.wait_for("Message 2", timeout=12), "FAIL: Message 2 not delivered"

    idx1 = next(i for i, m in enumerate(bob.received) if "Message 1" in m)
    idx2 = next(i for i, m in enumerate(bob.received) if "Message 2" in m)
    assert idx1 < idx2, "FAIL: Messages out of order"

    alice.stop(); bob.stop()
    print("PASS\n")


def scenario_c():
    print("--- Scenario C: Full Alice/Bob cross-platform ---")
    alice = CLIClient("swift",  "alice_c")
    bob   = CLIClient("kotlin", "bob_c")

    alice.send("bob_c", "Hi Bob, I have something important to tell you")
    assert bob.wait_for("important"), "FAIL: Bob did not receive Alice's first message"

    bob.send("alice_c", "What is it?")
    assert alice.wait_for("What is it"), "FAIL: Alice did not receive Bob's message"

    alice.go_offline()
    alice.send("bob_c", "It's about our trip")

    bob.go_offline()
    bob.send("alice_c", "I'm waiting")

    alice.go_online()
    assert bob.wait_for("our trip", timeout=12), \
        "FAIL: Alice's queued message not received"

    alice.go_offline()
    bob.go_online()
    assert alice.wait_for("waiting", timeout=12), \
        "FAIL: Bob's queued message not received"

    alice.stop(); bob.stop()
    print("PASS\n")


if __name__ == "__main__":
    scenario_a()
    scenario_b()
    scenario_c()
    print("✓ All scenarios passed")
```

```bash
# Run all tests
cd server && uvicorn main:app --port 8765 &
sleep 2
python tests/integration_test.py
```

```bash
git add tests/
git commit -m "test: add integration test harness and run all scenarios"
```

---

## Step 10: Documentation

### `DESIGN.md`
```markdown
# Design Decisions

## Protocol: HTTP polling only (no WebSocket)
Simple to spec, simple to generate, simple to test.
WebSocket adds reconnection complexity that diverges across platforms.
3-second poll is fine for a demo; WebSocket is a FUTURE.md item.

## CLI clients, not mobile apps
iOS Simulator and Android Emulator can't be driven from a Python test harness.
Swift CLI (Swift Package Manager) and Kotlin JVM (Gradle application) run as
regular processes — testable with subprocess.Popen. Mobile UI is a FUTURE.md item.

## No YAML spec parser
The spec is Markdown injected directly into prompts.
No intermediate data model, no parser that can fail, fewer moving parts.

## localId / serverId split in offline queue
A queued message has no server ID until the POST /send ACK.
Two-field design prevents ID collisions and makes deduplication unambiguous.

## Compile-check retry loop in generator
LLMs produce non-compilable code on first attempt ~30% of the time.
The harness auto-retries once with compiler errors injected into the prompt.
This makes regeneration reliable without manual intervention.

## Reproducibility = behavioral equivalence
Generated code will differ in variable names and structure between runs.
The spec + prompt templates are the reproducibility artifact.
Same spec + same prompts = clients that pass the same integration tests.
```

### `AGENTS.md`
```markdown
# How Claude Code Is Used

## Invocation
The generator calls claude in non-interactive mode:
  echo "<prompt>" | claude --print

Verify this works before running the generator:
  echo "Write hello world in Python" | claude --print

## Prompt Structure
Each platform has a template in generator/prompts/<lang>_prompt.md.
The {{SPEC}} placeholder is replaced with the full contents of spec/protocol-spec.md.
The spec is injected verbatim — not summarized, not parsed.

## Generation Loop
generate.py calls Claude, extracts files matching:
  ```swift\n// filename: FileName.swift\n<content>\n```
then runs swift build or ./gradlew compileKotlin.
If compilation fails, errors are appended to the prompt and Claude is called again.
Maximum 2 attempts before the script exits for manual intervention.

## What Claude Code generates
- All .swift files in clients/swift/Sources/messaging-cli/
- All .kt files in clients/kotlin/app/src/main/kotlin/com/messaging/

## What is hand-written (not generated)
- The spec (spec/protocol-spec.md)
- The generator harness (generator/)
- The server (server/)
- Build scaffolding (Package.swift, build.gradle)
- Integration tests (tests/)
```

### `FUTURE.md`
```markdown
# What's Next

## Mobile UI (highest value)
The protocol layer is already correct. Add:
- SwiftUI view over MessageClient.swift for iOS
- Compose UI over MessageClient.kt for Android
The generator prompts need a new template variant: swift_ios_prompt.md / kotlin_android_prompt.md.

## WebSocket for real-time delivery
Replace polling loop with WebSocket connection.
Server sends push events on new messages.
Spec addition: WS endpoint /ws, event format, reconnect semantics.
Generator prompts updated to use URLWebSocketTask (Swift) / OkHttp WS (Kotlin).

## Attachments
Spec change: add optional attachment field to WireMessage:
  "attachment": { "url": "string", "mimeType": "string", "size": int }
Server: serve file from memory or temp storage.
Generator: re-run with updated spec — clients handle new field.

## Read receipts
Spec change: add readAt field (int64 | null) to WireMessage.
New endpoint: POST /read { messageId }
Generator: re-run — clients send receipt on message display.

## Group conversations
Spec change: replace "to": string with "recipients": [string].
Server and client changes are minimal — generator re-run handles it.

## Message reactions
New endpoint: POST /react { messageId, emoji }
New field on WireMessage: reactions: [{ emoji, username }]

## Spec evolution guarantee
Any of the above can be added to protocol-spec.md and the generator
re-run. The harness requires no changes — only the spec and prompts evolve.
```

### `README.md`
```markdown
# Spec-Driven Messaging Code Generator

Turns a protocol spec into working CLI clients via Claude Code.

## Requirements
- Python 3.11+
- Swift 5.9+, macOS
- Kotlin 1.9+ / JDK 17+
- Claude Code: `npm install -g @anthropic-ai/claude-code`
- Verify: `echo "hello" | claude --print`

## Quick Start

```bash
# 1. Start server
cd server && pip install -r requirements.txt
uvicorn main:app --port 8765

# 2. Generate clients
python generator/generate.py --lang swift  --output clients/swift/Sources/messaging-cli/
python generator/generate.py --lang kotlin --output clients/kotlin/app/src/main/kotlin/com/messaging/

# 3. Run integration tests
python tests/integration_test.py
```

## Regeneration
To verify from scratch:
```bash
rm clients/swift/Sources/messaging-cli/*.swift
rm clients/kotlin/app/src/main/kotlin/com/messaging/*.kt
python generator/generate.py --lang swift  --output clients/swift/Sources/messaging-cli/
python generator/generate.py --lang kotlin --output clients/kotlin/app/src/main/kotlin/com/messaging/
python tests/integration_test.py
```

## What is generated vs hand-written
- **Generated**: all .swift and .kt files in clients/
- **Hand-written**: spec/, generator/, server/, tests/, Package.swift, build.gradle

## Where to find things
- Spec: `spec/protocol-spec.md`
- Generator: `generator/generate.py`
- Prompts: `generator/prompts/`
- Generated clients: `clients/swift/` and `clients/kotlin/`
- Server: `server/`
- Tests: `tests/`
```

```bash
git add DESIGN.md AGENTS.md FUTURE.md README.md
git commit -m "docs: add DESIGN, AGENTS, FUTURE, README"
```

---

## Step 11: Final Regeneration Verification

```bash
# Delete all generated code
rm clients/swift/Sources/messaging-cli/*.swift
rm clients/kotlin/app/src/main/kotlin/com/messaging/*.kt

# Regenerate
python generator/generate.py --lang swift  --output clients/swift/Sources/messaging-cli/
python generator/generate.py --lang kotlin --output clients/kotlin/app/src/main/kotlin/com/messaging/

# Start server
cd server && uvicorn main:app --port 8765 &
sleep 2

# Run tests
python tests/integration_test.py

# Expected output:
# --- Scenario A: Basic send/receive ---
# PASS
# --- Scenario B: Offline queue FIFO ---
# PASS
# --- Scenario C: Full Alice/Bob cross-platform ---
# PASS
# ✓ All scenarios passed
```

```bash
git add .
git commit -m "chore: verify regeneration — all scenarios pass"
```

---

## Commit History Summary

```
1.  feat: initial project structure
2.  feat: add Python server with in-memory store
3.  feat: add messaging protocol spec v1.0
4.  feat: add generator harness with compile-check retry loop
5.  feat: add Swift and Kotlin generation prompt templates
6.  feat: add Swift and Kotlin build scaffolding
7.  feat: generate Swift and Kotlin CLI clients          ← generated files
8.  fix: update prompts based on smoke test findings     ← if needed
9.  test: add integration test harness and run all scenarios
10. docs: add DESIGN, AGENTS, FUTURE, README
11. chore: verify regeneration — all scenarios pass
```

---

## Time Estimate

| Step | Time |
|------|------|
| 0. Environment check | 15 min |
| 1. Repo structure | 10 min |
| 2. Python server | 45 min |
| 3. Spec | 60 min |
| 4. Generator harness | 45 min |
| 5. Prompt templates | 45 min |
| 6. Build scaffolding | 20 min |
| 7. Generate + iterate | 60 min |
| 8. Smoke tests | 20 min |
| 9. Integration tests | 45 min |
| 10. Documentation | 30 min |
| 11. Regeneration verify | 15 min |
| **Total** | **~7 hours** |

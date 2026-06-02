# Spec-Driven Messaging Code Generator

Turns a protocol spec into working CLI clients via Claude Code.

## Requirements
- Python 3.10+
- Swift 5.9+, macOS
- Kotlin 1.9+ / JDK 17+
- Claude Code: `npm install -g @anthropic-ai/claude-code`
- Verify: `echo "hello" | claude --print`

## Quick Start

```bash
# 1. Start server
cd server && pip3 install -r requirements.txt
python3 -m uvicorn main:app --port 8765

# 2. Generate clients
python3 generator/generate.py --lang swift  --output clients/swift/Sources/messaging-cli/
python3 generator/generate.py --lang kotlin --output clients/kotlin/src/main/kotlin/com/messaging/

# 3. Run integration tests
python3 tests/integration_test.py
```

## Building Clients

### Swift
```bash
cd clients/swift
swift build              # Debug build
swift build -c release  # Release build

# With credentials (auto-registers if user doesn't exist)
.build/debug/messaging-cli --user ben --password ben

# Interactive mode
.build/debug/messaging-cli
```

### Kotlin
```bash
cd clients/kotlin
./gradlew build    # Compile + check

# Run via Gradle (stdin is wired — interactive prompts work)
./gradlew run --args='--user kein --password kein'

# Interactive mode (no credentials — prompts for register or login)
./gradlew run

# Build and run as a standalone JAR
./gradlew jar
java -jar build/libs/messaging-cli-1.0.jar --user alice --password secret
```

### CLI Commands
Once authenticated:
```
send <username> <message>   # Send a message to another user
offline                      # Simulate going offline (messages are queued)
online                       # Simulate coming back online (queue is flushed)
quit                         # Logout and exit
```

**Example session:**
```
$ .build/debug/messaging-cli --user alice --password secret
Logging in as alice...
✓ Connected
Ready. Type 'send <user> <message>' or 'quit'
> send bob Hello from Alice!
✓ Sent to bob
> 
📩 Message from bob: Hi Alice, got your message!
> quit
Logging out...
```

## Auth Flow

When `--user` and `--password` are passed, the client tries to login first.
If the user doesn't exist yet, it automatically registers and logs in —
no manual registration step needed.

In interactive mode (no flags), the client asks whether to register or login.

The integration test pre-registers all test users automatically before launching clients.

```
POST /register { "username": "alice", "password": "secret" }
→ 201 { "userId": "...", "username": "alice" }
→ 409 { "error": "username_taken" }

POST /login { "username": "alice", "password": "secret" }
→ 200 { "userId": "...", "username": "alice", "sessionId": "..." }
→ 401 { "error": "invalid_credentials" }
```

## Regeneration

To regenerate from scratch and verify everything still passes:
```bash
rm clients/swift/Sources/messaging-cli/*.swift
rm clients/kotlin/src/main/kotlin/com/messaging/*.kt
python3 generator/generate.py --lang swift  --output clients/swift/Sources/messaging-cli/
python3 generator/generate.py --lang kotlin --output clients/kotlin/src/main/kotlin/com/messaging/
python3 tests/integration_test.py
```

## Project Layout

| Path | Description |
|------|-------------|
| `spec/protocol-spec.md` | The protocol spec that drives generation |
| `generator/generate.py` | Generator harness (calls Claude, compile-checks, retries) |
| `generator/prompts/` | Per-language prompt templates |
| `clients/swift/` | Swift CLI client |
| `clients/kotlin/` | Kotlin JVM CLI client |
| `server/` | Hand-written FastAPI server |
| `tests/` | Integration test harness |

## What is generated vs hand-written
- **Generated**: all `.swift` and `.kt` files under `clients/`
- **Hand-written**: `spec/`, `generator/`, `server/`, `tests/`, `Package.swift`, `build.gradle`

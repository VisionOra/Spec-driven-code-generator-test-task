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

# Register & login
.build/debug/messaging-cli --user alice --password secret

# Interactive mode (prompts for register/login)
.build/debug/messaging-cli
```

### Kotlin
```bash
cd clients/kotlin
./gradlew build                # Full build (compile + tests)

# Register & login
./gradlew run --args "--user alice --password secret"

# Or run the JAR directly
java -jar build/libs/messaging-cli-1.0-all.jar --user alice --password secret
```

### Messaging Commands
Once authenticated, you can:
```
send <username> <message>   # Send a message to another user
offline                      # Simulate offline (queues messages)
online                       # Simulate back online (flushes queue)
quit                         # Logout and exit
```

**Example interaction:**
```
$ .build/debug/messaging-cli --user alice --password secret
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

Users must register before logging in:

```
# Register
POST /register { "username": "alice", "password": "secret" }
→ 201 { "userId": "...", "username": "alice" }
→ 409 { "error": "username_taken" }   # if name already taken

# Login
POST /login { "username": "alice", "password": "secret" }
→ 200 { "userId": "...", "username": "alice", "sessionId": "..." }
→ 401 { "error": "invalid_credentials" }
```

## Regeneration
To verify from scratch:
```bash
rm clients/swift/Sources/messaging-cli/*.swift
rm clients/kotlin/src/main/kotlin/com/messaging/*.kt
python3 generator/generate.py --lang swift  --output clients/swift/Sources/messaging-cli/
python3 generator/generate.py --lang kotlin --output clients/kotlin/src/main/kotlin/com/messaging/
python3 tests/integration_test.py
```

## What is generated vs hand-written
- **Generated**: all .swift and .kt files in clients/
- **Hand-written**: spec/, generator/, server/, tests/, Package.swift, build.gradle

## Where to find things
- Spec: `spec/protocol-spec.md`
- Generator: `generator/generate.py`
- Prompts: `generator/prompts/`
- Generated Swift client: `clients/swift/Sources/messaging-cli/`
- Generated Kotlin client: `clients/kotlin/src/main/kotlin/com/messaging/`
- Server: `server/`
- Tests: `tests/`

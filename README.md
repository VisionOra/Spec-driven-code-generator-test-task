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

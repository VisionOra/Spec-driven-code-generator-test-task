# Design Decisions

## Auth: registration + password validation
Registration (POST /register) and login (POST /login) are distinct operations.
Registration returns 409 if a username is already taken — clients must surface this and ask for a different name.
Login returns 401 for both wrong password and unknown username (same error prevents username enumeration).
Passwords are bcrypt-hashed server-side; plaintext is never stored.

## Protocol: HTTP polling only (no WebSocket)
Simple to spec, simple to generate, simple to test.
WebSocket adds reconnection complexity that diverges across platforms.
3-second poll is fine for a demo; WebSocket is a FUTURE.md item.

## CLI clients, not mobile apps
iOS Simulator and Android Emulator can't be driven from a Python test harness.
Swift CLI (Swift Package Manager) and Kotlin JVM (Gradle application) run as
regular processes — testable with subprocess.Popen. Mobile UI is a FUTURE.md item.

## Gradle stdin wiring
`./gradlew run` does not connect stdin to the process by default — `readLine()` returns
null immediately, silently skipping the interactive auth prompt.
`build.gradle` adds `run { standardInput = System.in }` to fix this.
Running via `java -jar` is unaffected; stdin always works there.

## No YAML spec parser
The spec is Markdown injected directly into prompts.
No intermediate data model, no parser that can fail, fewer moving parts.

## localId / serverId split in offline queue
A queued message has no server ID until the POST /send ACK.
Two-field design prevents ID collisions and makes deduplication unambiguous.

## Generator uses --dangerously-skip-permissions
Claude Code's subprocess writes files directly to disk instead of parsing stdout.
This avoids fragile regex-based file extraction and matches how Claude Code naturally works.
The `--add-dir` flag scopes write access to only the client output directory.
The compile-check retry loop still catches any code errors.

## Compile-check retry loop in generator
LLMs produce non-compilable code on first attempt ~30% of the time.
The harness auto-retries once with compiler errors injected into the prompt.
This makes regeneration reliable without manual intervention.

## RECEIVED prefix in onMessageReceived
Both clients print `RECEIVED from <user>: <text>` when a new message arrives.
This machine-readable line lets the integration test harness detect delivery
without parsing the conversational UI output. The user-facing display follows on
the next line (Swift: `📩 Message from …`, Kotlin: same via the callback).

## Integration test pre-registers users
The test harness calls POST /register before launching each client process.
This lets clients be started with `--user` and `--password` flags, bypassing
the interactive auth prompt so processes can be driven entirely from stdin/stdout.
A 409 response (username already exists) is silently ignored so the same usernames
can be reused across test runs without clearing the database.

## Reproducibility = behavioral equivalence
Generated code will differ in variable names and structure between runs.
The spec + prompt templates are the reproducibility artifact.
Same spec + same prompts = clients that pass the same integration tests.

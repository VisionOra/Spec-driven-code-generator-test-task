# How Claude Code Is Used

## Invocation

The generator calls Claude Code in non-interactive mode with file-write permissions:

```bash
claude --print --dangerously-skip-permissions --add-dir <output_dir>
```

- `--print` — non-interactive, returns when done
- `--dangerously-skip-permissions` — lets Claude write files without per-file prompts
- `--add-dir <output_dir>` — grants write access to the client output directory

Verify the setup before running the generator:
```bash
echo "Write hello world in Python" | claude --print
```

## Prompt Structure

Each platform has a template in `generator/prompts/<lang>_prompt.md`.
Two placeholders are replaced at generation time:

| Placeholder | Replaced with |
|-------------|---------------|
| `{{SPEC}}` | Full contents of `spec/protocol-spec.md` |
| `{{OUTPUT_DIR}}` | Absolute path where Claude should write files |

The spec is injected verbatim — not summarized, not parsed.

## Generation Loop

`generate.py` calls Claude, waits for it to write files to disk, then runs:
- `swift build` (Swift)
- `./gradlew compileKotlin` (Kotlin)

If compilation fails, errors are appended to the prompt and Claude is called again.
Maximum 2 attempts before the script exits for manual intervention.

## Callback Convention

Both clients expose three callbacks that the test harness and CLI rely on:

| Callback | Triggered when |
|----------|---------------|
| `onMessageReceived` | A new message arrives from the sync loop |
| `onStateChange` | Client state changes (`online`, `offline`, `flushing`, …) |
| `onError` | A user-facing error occurs |

When `onMessageReceived` fires, clients print `RECEIVED from <user>: <text>` to stdout.
The integration test's reader thread captures lines containing `RECEIVED` to verify delivery.

## Client States

Both clients implement the same 6-state machine:

```
LOGGED_OUT → REGISTERING → LOGGED_OUT   (after register)
LOGGED_OUT → LOGGING_IN  → ONLINE       (after successful login)
ONLINE     → OFFLINE                    (network lost)
ONLINE     → FLUSHING    → ONLINE       (flush pending queue)
OFFLINE    → FLUSHING / ONLINE          (network restored)
ANY        → LOGGED_OUT                 (401 from server)
```

## What Claude Code Generates
- All `.swift` files in `clients/swift/Sources/messaging-cli/`
- All `.kt` files in `clients/kotlin/src/main/kotlin/com/messaging/`

## What is Hand-Written (not generated)
- The spec (`spec/protocol-spec.md`)
- The generator harness (`generator/`)
- The server (`server/`)
- Build scaffolding (`Package.swift`, `build.gradle`, `settings.gradle`)
- Integration tests (`tests/`)

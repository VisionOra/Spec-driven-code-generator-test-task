# How Claude Code Is Used

## Invocation
The generator calls claude in non-interactive mode with file-write permissions:
  echo "<prompt>" | claude --print --dangerously-skip-permissions --add-dir <output_dir>

Claude writes source files directly to the output directory using its file tools.

Verify this works before running the generator:
  echo "Write hello world in Python" | claude --print

## Prompt Structure
Each platform has a template in generator/prompts/<lang>_prompt.md.
Two placeholders are replaced at generation time:
  - {{SPEC}}       → full contents of spec/protocol-spec.md
  - {{OUTPUT_DIR}} → absolute path where Claude should write the files

The spec is injected verbatim — not summarized, not parsed.

## Generation Loop
generate.py calls Claude, waits for it to write files to disk, then runs:
  swift build           (for Swift)
  ./gradlew compileKotlin  (for Kotlin)

If compilation fails, errors are appended to the prompt and Claude is called again.
Maximum 2 attempts before the script exits for manual intervention.

## What Claude Code generates
- All .swift files in clients/swift/Sources/messaging-cli/
- All .kt files in clients/kotlin/src/main/kotlin/com/messaging/

## What is hand-written (not generated)
- The spec (spec/protocol-spec.md)
- The generator harness (generator/)
- The server (server/)
- Build scaffolding (Package.swift, build.gradle, settings.gradle)
- Integration tests (tests/)

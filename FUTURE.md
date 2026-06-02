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

## Password reset
New endpoints: POST /request-reset { username }, POST /reset-password { token, newPassword }
Server sends token out-of-band (email or printed to console for demo).

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

## Spec evolution guarantee
Any of the above can be added to protocol-spec.md and the generator
re-run. The harness requires no changes — only the spec and prompts evolve.

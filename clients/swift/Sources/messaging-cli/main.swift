import Foundation

// MARK: - Arg parsing

var serverURL = "http://localhost:8765"
var argUser: String? = nil
var argPassword: String? = nil

var argList = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argList.count {
    switch argList[i] {
    case "--server":   i += 1; if i < argList.count { serverURL = argList[i] }
    case "--user":     i += 1; if i < argList.count { argUser = argList[i] }
    case "--password": i += 1; if i < argList.count { argPassword = argList[i] }
    default: break
    }
    i += 1
}

// MARK: - Setup

let client = MessageClient(serverURL: serverURL)

await client.setupNetworkMonitor()

await client.setCallbacks(
    onMessageReceived: { msg in
        print("\n📩 Message from \(msg.fromUser): \(msg.text)")
        print("> ", terminator: "")
        fflush(stdout)
    },
    onStateChange: { state in
        // Only print state changes that matter to the user
        switch state {
        case "online":   print("✓ Connected")
        case "offline":  print("⚠ Offline — messages will be queued")
        case "flushing": print("↑ Sending queued messages...")
        default: break
        }
    },
    onError: { reason in
        print("✗ \(reason)")
    }
)

let networkMonitor = await client.networkMonitor

// MARK: - Auth flow

func promptLine(_ label: String) -> String {
    print(label, terminator: "")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
}

if let u = argUser, let p = argPassword {
    // Args provided — login directly
    print("Logging in as \(u)...")
    let ok = await client.login(username: u, password: p)
    if !ok { exit(1) }
} else {
    // Interactive auth flow — retry until success
    var loggedIn = false
    while !loggedIn {
        let choice = promptLine("register or login? ").lowercased()

        if choice.hasPrefix("r") {
            let username = promptLine("username: ")
            let password = promptLine("password: ")
            let ok = await client.register(username: username, password: password)
            if ok {
                print("✓ Account created. Logging you in...")
                let loginOk = await client.login(username: username, password: password)
                if loginOk { loggedIn = true }
            }
            // If failed, loop repeats and asks again
        } else {
            let username = promptLine("username: ")
            let password = promptLine("password: ")
            let ok = await client.login(username: username, password: password)
            if ok { loggedIn = true }
            // If failed, loop repeats and asks again
        }
    }
}

// MARK: - Message loop
// Read stdin on a dedicated thread so the cooperative thread pool
// (which runs the 3-second sync loop) is never blocked by readLine().

print("Ready. Type 'send <user> <message>' or 'quit'")
print("> ", terminator: "")
fflush(stdout)

// Bridge blocking readLine() into async world without starving the thread pool.
func nextLine() async -> String? {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInteractive).async {
            cont.resume(returning: readLine())
        }
    }
}

while let line = await nextLine() {
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if trimmed.isEmpty {
        // nothing
    } else if trimmed == "quit" {
        print("Logging out...")
        await client.logout()
        exit(0)
    } else if trimmed.hasPrefix("send ") {
        let rest = String(trimmed.dropFirst(5))
        if let spaceIdx = rest.firstIndex(of: " ") {
            let toUser = String(rest[rest.startIndex..<spaceIdx])
            let text   = String(rest[rest.index(after: spaceIdx)...])
            await client.sendMessage(to: toUser, text: text)
            print("✓ Sent to \(toUser)")
        } else {
            print("Usage: send <username> <message text>")
        }
    // Hidden test commands for offline queue simulation
    } else if trimmed == "offline" {
        networkMonitor.simulateOffline()
    } else if trimmed == "online" {
        networkMonitor.simulateOnline()
    } else {
        print("Commands: send <user> <message> | quit")
    }

    print("> ", terminator: "")
    fflush(stdout)
}

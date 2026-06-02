import Foundation

// MARK: - Arg parsing

var serverURL = "http://localhost:8765"
var argUser: String? = nil
var argPassword: String? = nil

var args = CommandLine.arguments.dropFirst()
var argList = Array(args)
var i = 0
while i < argList.count {
    switch argList[i] {
    case "--server":
        i += 1
        if i < argList.count { serverURL = argList[i] }
    case "--user":
        i += 1
        if i < argList.count { argUser = argList[i] }
    case "--password":
        i += 1
        if i < argList.count { argPassword = argList[i] }
    default:
        break
    }
    i += 1
}

// MARK: - Interactive prompt helpers

func prompt(_ message: String) -> String {
    print(message, terminator: "")
    return readLine() ?? ""
}

// MARK: - Main async entry point

let client = MessageClient(serverURL: serverURL)

await client.setupNetworkMonitor()

await client.setCallbacks(
    onMessageReceived: { msg in
        print("RECEIVED from \(msg.fromUser): \(msg.text)")
    },
    onStateChange: { state in
        print("STATE: \(state)")
    },
    onError: { reason in
        print("ERROR: \(reason)")
    }
)

let networkMonitor = await client.networkMonitor

enum AuthAction { case register, login }
var action: AuthAction
var username: String
var password: String

if let u = argUser, let p = argPassword {
    username = u
    password = p
    action = .login
} else {
    let choice = prompt("register or login? ").trimmingCharacters(in: .whitespaces).lowercased()
    action = choice.hasPrefix("r") ? .register : .login
    username = prompt("username: ").trimmingCharacters(in: .whitespaces)
    password = prompt("password: ").trimmingCharacters(in: .whitespaces)
}

if action == .register {
    await client.register(username: username, password: password)
    print("Registration complete. Please login.")
    let loginChoice = prompt("login now? (y/n): ").trimmingCharacters(in: .whitespaces).lowercased()
    if loginChoice.hasPrefix("y") {
        await client.login(username: username, password: password)
    } else {
        exit(0)
    }
} else {
    await client.login(username: username, password: password)
}

// MARK: - Read loop

print("Type 'send <user> <message>', 'offline', 'online', or 'quit'")
while let line = readLine() {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { continue }

    if trimmed == "quit" {
        await client.logout()
        exit(0)
    } else if trimmed == "offline" {
        networkMonitor.simulateOffline()
    } else if trimmed == "online" {
        networkMonitor.simulateOnline()
    } else if trimmed.hasPrefix("send ") {
        let rest = String(trimmed.dropFirst(5))
        if let spaceIdx = rest.firstIndex(of: " ") {
            let toUser = String(rest[rest.startIndex..<spaceIdx])
            let text = String(rest[rest.index(after: spaceIdx)...])
            await client.sendMessage(to: toUser, text: text)
        } else {
            print("Usage: send <username> <message text>")
        }
    } else {
        print("Unknown command. Use: send <user> <msg> | offline | online | quit")
    }
}

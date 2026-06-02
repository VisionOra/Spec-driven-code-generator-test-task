import Foundation

actor MessageClient {
    enum State: String {
        case loggedOut
        case registering
        case loggingIn
        case online
        case flushing
        case offline
    }

    var serverURL: String
    var onMessageReceived: ((WireMessage) -> Void)?
    var onStateChange: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let network = NetworkClient()
    private var queue: OfflineQueue?   // created after login with username-scoped path
    private var state: State = .loggedOut
    private var sessionId: String?
    private var currentUser: String?
    private var lastServerTimestamp: Int64 = 0
    private var syncTask: Task<Void, Never>?
    let networkMonitor = NetworkMonitor()

    init(serverURL: String) {
        self.serverURL = serverURL
    }

    func setCallbacks(
        onMessageReceived: @escaping (WireMessage) -> Void,
        onStateChange: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.onMessageReceived = onMessageReceived
        self.onStateChange = onStateChange
        self.onError = onError
    }

    func setupNetworkMonitor() {
        networkMonitor.onStatusChange = { [weak self] isOnline in
            Task { [weak self] in
                await self?.handleNetworkChange(isOnline: isOnline)
            }
        }
    }

    private func handleNetworkChange(isOnline: Bool) async {
        if isOnline {
            guard state == .offline else { return }
            if queue?.nextPending() != nil {
                await transition(to: .flushing)
                await flushQueue()
            } else {
                await transition(to: .online)
                startSyncLoop(immediate: true)
            }
        } else {
            if state == .online || state == .flushing {
                syncTask?.cancel()
                syncTask = nil
                await transition(to: .offline)
            }
        }
    }

    func register(username: String, password: String) async -> Bool {
        guard state == .loggedOut else { return false }
        await transition(to: .registering)
        do {
            _ = try await network.register(username: username, password: password, serverURL: serverURL)
            await transition(to: .loggedOut)
            return true
        } catch NetworkError.usernameTaken {
            onError?("username_taken")
            await transition(to: .loggedOut)
            return false
        } catch NetworkError.connectionFailed {
            onError?("Cannot reach server. Make sure the server is running on \(serverURL)")
            await transition(to: .loggedOut)
            return false
        } catch {
            onError?("Registration failed: \(error.localizedDescription)")
            await transition(to: .loggedOut)
            return false
        }
    }

    func login(username: String, password: String) async -> Bool {
        guard state == .loggedOut else { return false }
        await transition(to: .loggingIn)
        do {
            let resp = try await network.login(username: username, password: password, serverURL: serverURL)
            sessionId = resp.sessionId
            currentUser = resp.username
            queue = OfflineQueue(username: resp.username)  // user-scoped DB
            await transition(to: .online)
            startSyncLoop(immediate: true)
            return true
        } catch NetworkError.unauthorized {
            onError?("Wrong username or password.")
            await transition(to: .loggedOut)
            return false
        } catch NetworkError.connectionFailed {
            onError?("Cannot reach server. Make sure the server is running on \(serverURL)")
            await transition(to: .loggedOut)
            return false
        } catch {
            onError?("Login failed: \(error.localizedDescription)")
            await transition(to: .loggedOut)
            return false
        }
    }

    func sendMessage(to: String, text: String) async {
        guard let q = queue else { return }
        let localId = q.enqueue(to: to, text: text)

        switch state {
        case .online:
            guard let sid = sessionId else { return }
            q.markSending(localId: localId)
            do {
                let resp = try await network.send(to: to, text: text, sessionId: sid, serverURL: serverURL)
                q.markSent(localId: localId, serverId: resp.id)
            } catch NetworkError.unauthorized {
                q.markPending(localId: localId)
                await handleUnauthorized()
            } catch NetworkError.connectionFailed {
                q.markPending(localId: localId)
                syncTask?.cancel()
                syncTask = nil
                await transition(to: .offline)
            } catch {
                q.markPending(localId: localId)
                syncTask?.cancel()
                syncTask = nil
                await transition(to: .flushing)
                await flushQueue()
            }
        case .flushing, .offline:
            break
        default:
            break
        }
    }

    func logout() async {
        if let sid = sessionId {
            await network.logout(sessionId: sid, serverURL: serverURL)
        }
        sessionId = nil
        currentUser = nil
        syncTask?.cancel()
        syncTask = nil
        await transition(to: .loggedOut)
    }

    private func transition(to newState: State) async {
        state = newState
        onStateChange?(newState.rawValue)
    }

    private func startSyncLoop(immediate: Bool) {
        syncTask?.cancel()
        syncTask = Task {
            if immediate {
                await pollMessages()
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await pollMessages()
            }
        }
    }

    private func pollMessages() async {
        guard let sid = sessionId, state == .online else { return }
        do {
            let resp = try await network.getMessages(since: lastServerTimestamp, sessionId: sid, serverURL: serverURL)
            lastServerTimestamp = resp.serverTimestamp
            for msg in resp.messages {
                if queue?.isDuplicate(serverId: msg.id) == true { continue }
                onMessageReceived?(msg)
            }
        } catch NetworkError.unauthorized {
            await handleUnauthorized()
        } catch NetworkError.connectionFailed {
            syncTask?.cancel()
            syncTask = nil
            await transition(to: .offline)
        } catch {
            // transient error — continue loop
        }
    }

    private func flushQueue() async {
        guard state == .flushing, let sid = sessionId, let q = queue else { return }

        while true {
            guard let msg = q.nextPending() else {
                await transition(to: .online)
                startSyncLoop(immediate: true)
                return
            }

            q.markSending(localId: msg.localId)

            do {
                let resp = try await network.send(to: msg.toUser, text: msg.text, sessionId: sid, serverURL: serverURL)
                q.markSent(localId: msg.localId, serverId: resp.id)
            } catch NetworkError.unauthorized {
                q.markPending(localId: msg.localId)
                await handleUnauthorized()
                return
            } catch NetworkError.connectionFailed {
                q.markPending(localId: msg.localId)
                await transition(to: .offline)
                return
            } catch NetworkError.serverError(let code) where code >= 500 {
                q.markFailed(localId: msg.localId)
            } catch {
                q.markFailed(localId: msg.localId)
            }
        }
    }

    private func handleUnauthorized() async {
        sessionId = nil
        currentUser = nil
        syncTask?.cancel()
        syncTask = nil
        await transition(to: .loggedOut)
    }
}

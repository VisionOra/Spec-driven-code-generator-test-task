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
    private let queue = OfflineQueue()
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
            if queue.nextPending() != nil {
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

    func register(username: String, password: String) async {
        guard state == .loggedOut else { return }
        await transition(to: .registering)
        do {
            _ = try await network.register(username: username, password: password, serverURL: serverURL)
            await transition(to: .loggedOut)
        } catch NetworkError.usernameTaken {
            onError?("username_taken")
            await transition(to: .loggedOut)
        } catch {
            onError?("registration_failed: \(error)")
            await transition(to: .loggedOut)
        }
    }

    func login(username: String, password: String) async {
        guard state == .loggedOut else { return }
        await transition(to: .loggingIn)
        do {
            let resp = try await network.login(username: username, password: password, serverURL: serverURL)
            sessionId = resp.sessionId
            currentUser = resp.username
            await transition(to: .online)
            startSyncLoop(immediate: true)
        } catch NetworkError.unauthorized {
            onError?("invalid_credentials")
            await transition(to: .loggedOut)
        } catch {
            onError?("login_failed: \(error)")
            await transition(to: .loggedOut)
        }
    }

    func sendMessage(to: String, text: String) async {
        let localId = queue.enqueue(to: to, text: text)

        switch state {
        case .online:
            guard let sid = sessionId else { return }
            queue.markSending(localId: localId)
            do {
                let resp = try await network.send(to: to, text: text, sessionId: sid, serverURL: serverURL)
                queue.markSent(localId: localId, serverId: resp.id)
            } catch NetworkError.unauthorized {
                queue.markPending(localId: localId)
                await handleUnauthorized()
            } catch NetworkError.connectionFailed {
                queue.markPending(localId: localId)
                syncTask?.cancel()
                syncTask = nil
                await transition(to: .flushing)
                await transition(to: .offline)
            } catch {
                queue.markPending(localId: localId)
                syncTask?.cancel()
                syncTask = nil
                await transition(to: .flushing)
                await flushQueue()
            }
        case .flushing, .offline:
            // Already queued above; nothing else to do
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
                if let serverId = msg.id as String?, queue.isDuplicate(serverId: serverId) { continue }
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
        guard state == .flushing, let sid = sessionId else { return }

        while true {
            guard let msg = queue.nextPending() else {
                // Queue drained
                await transition(to: .online)
                startSyncLoop(immediate: true)
                return
            }

            queue.markSending(localId: msg.localId)

            do {
                let resp = try await network.send(to: msg.toUser, text: msg.text, sessionId: sid, serverURL: serverURL)
                queue.markSent(localId: msg.localId, serverId: resp.id)
            } catch NetworkError.unauthorized {
                queue.markPending(localId: msg.localId)
                await handleUnauthorized()
                return
            } catch NetworkError.connectionFailed {
                queue.markPending(localId: msg.localId)
                await transition(to: .offline)
                return
            } catch NetworkError.serverError(let code) where code >= 500 {
                queue.markFailed(localId: msg.localId)
                // continue to next message
            } catch {
                queue.markFailed(localId: msg.localId)
                // continue to next message
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

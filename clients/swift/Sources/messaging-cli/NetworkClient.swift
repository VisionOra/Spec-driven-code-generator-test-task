import Foundation

class NetworkClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    func register(username: String, password: String, serverURL: String) async throws -> RegisterResponse {
        let body = ["username": username, "password": password]
        let (data, response) = try await post(path: "/register", body: body, serverURL: serverURL, sessionId: nil)
        let status = (response as! HTTPURLResponse).statusCode
        if status == 409 { throw NetworkError.usernameTaken }
        if status == 401 { throw NetworkError.unauthorized }
        if status >= 400 { throw NetworkError.serverError(status) }
        return try decoder.decode(RegisterResponse.self, from: data)
    }

    func login(username: String, password: String, serverURL: String) async throws -> LoginResponse {
        let body = ["username": username, "password": password]
        let (data, response) = try await post(path: "/login", body: body, serverURL: serverURL, sessionId: nil)
        let status = (response as! HTTPURLResponse).statusCode
        if status == 401 { throw NetworkError.unauthorized }
        if status >= 400 { throw NetworkError.serverError(status) }
        return try decoder.decode(LoginResponse.self, from: data)
    }

    func send(to: String, text: String, sessionId: String, serverURL: String) async throws -> SendResponse {
        let body = ["to": to, "text": text]
        let (data, response) = try await post(path: "/send", body: body, serverURL: serverURL, sessionId: sessionId)
        let status = (response as! HTTPURLResponse).statusCode
        if status == 401 { throw NetworkError.unauthorized }
        if status >= 400 { throw NetworkError.serverError(status) }
        return try decoder.decode(SendResponse.self, from: data)
    }

    func getMessages(since: Int64, sessionId: String, serverURL: String) async throws -> MessagesResponse {
        guard var components = URLComponents(string: serverURL + "/messages") else {
            throw NetworkError.connectionFailed
        }
        components.queryItems = [URLQueryItem(name: "since", value: String(since))]
        guard let url = components.url else { throw NetworkError.connectionFailed }

        var request = URLRequest(url: url)
        request.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw NetworkError.connectionFailed
        } catch {
            throw NetworkError.connectionFailed
        }

        let status = (response as! HTTPURLResponse).statusCode
        if status == 401 { throw NetworkError.unauthorized }
        if status >= 400 { throw NetworkError.serverError(status) }
        return try decoder.decode(MessagesResponse.self, from: data)
    }

    func logout(sessionId: String, serverURL: String) async {
        _ = try? await post(path: "/logout", body: [String: String](), serverURL: serverURL, sessionId: sessionId)
    }

    private func post(path: String, body: [String: String], serverURL: String, sessionId: String?) async throws -> (Data, URLResponse) {
        guard let url = URL(string: serverURL + path) else {
            throw NetworkError.connectionFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sid = sessionId {
            request.setValue(sid, forHTTPHeaderField: "X-Session-Id")
        }
        request.httpBody = try encoder.encode(body)

        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw NetworkError.connectionFailed
        } catch {
            throw NetworkError.connectionFailed
        }
    }
}

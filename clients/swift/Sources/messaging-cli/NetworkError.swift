enum NetworkError: Error {
    case unauthorized
    case usernameTaken
    case serverError(Int)
    case connectionFailed
}

package com.messaging

sealed class NetworkError : Exception() {
    object Unauthorized : NetworkError()
    object UsernameTaken : NetworkError()
    data class ServerError(val code: Int) : NetworkError()
    object ConnectionFailed : NetworkError()
}

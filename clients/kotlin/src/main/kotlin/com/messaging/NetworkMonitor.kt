package com.messaging

class NetworkMonitor {
    var isOnline: Boolean = true
    var onStatusChange: ((Boolean) -> Unit)? = null

    fun setOffline() {
        isOnline = false
        onStatusChange?.invoke(false)
    }

    fun setOnline() {
        isOnline = true
        onStatusChange?.invoke(true)
    }
}

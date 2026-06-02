package com.messaging

import kotlinx.coroutines.*
import kotlin.system.exitProcess

fun main(args: Array<String>): Unit = runBlocking {
    var user: String? = null
    var password: String? = null
    var serverURL = "http://localhost:8765"

    var i = 0
    while (i < args.size) {
        when (args[i]) {
            "--user" -> { i++; user = args[i] }
            "--password" -> { i++; password = args[i] }
            "--server" -> { i++; serverURL = args[i] }
        }
        i++
    }

    val networkMonitor = NetworkMonitor()
    val networkClient = NetworkClient()
    val offlineQueue = OfflineQueue()
    val client = MessageClient(serverURL, networkMonitor, networkClient, offlineQueue)

    client.onMessageReceived = { msg -> println("RECEIVED from ${msg.fromUser}: ${msg.text}") }
    client.onStateChange = { state -> println("STATE: $state") }
    client.onError = { reason -> println("ERROR: $reason") }

    if (user != null && password != null) {
        client.login(user, password)
        if (client.state != ClientState.ONLINE) {
            println("User not found — registering '$user'...")
            client.register(user, password)
            client.login(user, password)
        }
    } else {
        print("register or login? ")
        System.out.flush()
        val action = readLine()?.trim() ?: "login"
        print("username: ")
        System.out.flush()
        user = readLine() ?: ""
        print("password: ")
        System.out.flush()
        password = readLine() ?: ""

        if (action == "register") {
            client.register(user, password)
        } else {
            client.login(user, password)
        }
    }

    launch(Dispatchers.IO) {
        val stdin = System.`in`.bufferedReader()
        while (true) {
            val line = stdin.readLine() ?: break
            val trimmed = line.trim()
            when {
                trimmed.startsWith("send ") -> {
                    val rest = trimmed.removePrefix("send ")
                    val spaceIdx = rest.indexOf(' ')
                    if (spaceIdx != -1) {
                        val to = rest.substring(0, spaceIdx)
                        val text = rest.substring(spaceIdx + 1)
                        client.sendMessage(to, text)
                    }
                }
                trimmed == "offline" -> networkMonitor.setOffline()
                trimmed == "online" -> networkMonitor.setOnline()
                trimmed == "quit" -> {
                    client.logout()
                    exitProcess(0)
                }
            }
        }
    }

    awaitCancellation()
}

import threading, uuid, time

class Store:
    def __init__(self):
        self._lock = threading.Lock()
        self._users = {}     # username → {userId, sessionId}
        self._sessions = {}  # sessionId → username
        self._messages = []  # append-only

    def login(self, username: str) -> dict:
        with self._lock:
            session_id = str(uuid.uuid4())
            if username in self._users:
                self._sessions.pop(self._users[username]["sessionId"], None)
                self._users[username]["sessionId"] = session_id
            else:
                self._users[username] = {
                    "userId": str(uuid.uuid4()),
                    "username": username,
                    "sessionId": session_id
                }
            self._sessions[session_id] = username
            return dict(self._users[username])

    def get_user_by_session(self, session_id: str) -> str | None:
        return self._sessions.get(session_id)

    def send_message(self, from_user: str, to: str, text: str) -> dict:
        with self._lock:
            msg = {
                "id": str(uuid.uuid4()),
                "from": from_user,
                "to": to,
                "text": text,
                "timestamp": int(time.time() * 1000),
                "status": "delivered"
            }
            self._messages.append(msg)
            return msg

    def get_messages(self, for_user: str, since: int = 0) -> list:
        with self._lock:
            return [m for m in self._messages
                    if m["to"] == for_user and m["timestamp"] > since]

store = Store()

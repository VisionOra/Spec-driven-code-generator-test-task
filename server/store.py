import threading, uuid, time
import bcrypt

class Store:
    def __init__(self):
        self._lock = threading.Lock()
        self._users = {}     # username → {userId, username, passwordHash, sessionId}
        self._sessions = {}  # sessionId → username
        self._messages = []  # append-only

    def register(self, username: str, password: str) -> dict:
        with self._lock:
            if username in self._users:
                raise ValueError("username_taken")
            user_id = str(uuid.uuid4())
            self._users[username] = {
                "userId": user_id,
                "username": username,
                "passwordHash": bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode(),
                "sessionId": None,
            }
            return {"userId": user_id, "username": username}

    def login(self, username: str, password: str) -> dict:
        with self._lock:
            user = self._users.get(username)
            if not user or not bcrypt.checkpw(password.encode(), user["passwordHash"].encode()):
                raise ValueError("invalid_credentials")
            if user["sessionId"]:
                self._sessions.pop(user["sessionId"], None)
            session_id = str(uuid.uuid4())
            user["sessionId"] = session_id
            self._sessions[session_id] = username
            return {"userId": user["userId"], "username": username, "sessionId": session_id}

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

import threading, uuid, time, json, os
import bcrypt

DATA_FILE = os.path.expanduser("~/.messaging-server/data.json")

def _load():
    try:
        os.makedirs(os.path.dirname(DATA_FILE), exist_ok=True)
        with open(DATA_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"users": {}, "messages": []}

def _save(users, messages):
    os.makedirs(os.path.dirname(DATA_FILE), exist_ok=True)
    with open(DATA_FILE, "w") as f:
        json.dump({"users": users, "messages": messages}, f)

class Store:
    def __init__(self):
        self._lock = threading.Lock()
        data = _load()
        self._users = data["users"]      # username → {userId, username, passwordHash, sessionId}
        self._messages = data["messages"] # append-only list
        self._sessions = {}              # sessionId → username (rebuilt on boot; sessions don't persist)

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
            _save(self._users, self._messages)
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
            _save(self._users, self._messages)
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
            _save(self._users, self._messages)
            return msg

    def get_messages(self, for_user: str, since: int = 0) -> list:
        with self._lock:
            return [m for m in self._messages
                    if m["to"] == for_user and m["timestamp"] > since]

    def get_inbox(self, for_user: str) -> list:
        with self._lock:
            contacts = {}
            for m in self._messages:
                if m["to"] != for_user:
                    continue
                sender = m["from"]
                if sender not in contacts or m["timestamp"] > contacts[sender]["lastTimestamp"]:
                    contacts[sender] = {"lastTimestamp": m["timestamp"]}
                contacts[sender]["unread"] = contacts[sender].get("unread", 0) + (1 if not m.get("read") else 0)
            return sorted(
                [{"contact": c, "unread": v["unread"], "lastTimestamp": v["lastTimestamp"]}
                 for c, v in contacts.items()],
                key=lambda x: x["lastTimestamp"], reverse=True
            )

    def get_conversation(self, user_a: str, user_b: str) -> list:
        with self._lock:
            return [m for m in self._messages
                    if (m["from"] == user_a and m["to"] == user_b)
                    or (m["from"] == user_b and m["to"] == user_a)]

    def mark_read(self, from_user: str, to_user: str):
        with self._lock:
            for m in self._messages:
                if m["from"] == from_user and m["to"] == to_user:
                    m["read"] = True
            _save(self._users, self._messages)

store = Store()

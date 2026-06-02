from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from store import store

app = FastAPI()

class RegisterRequest(BaseModel):
    username: str
    password: str

class LoginRequest(BaseModel):
    username: str
    password: str

class SendRequest(BaseModel):
    to: str
    text: str

def auth(session_id: str | None) -> str:
    if not session_id:
        raise HTTPException(401, "Missing X-Session-Id header")
    user = store.get_user_by_session(session_id)
    if not user:
        raise HTTPException(401, "Invalid session")
    return user

@app.post("/register", status_code=201)
def register(req: RegisterRequest):
    try:
        return store.register(req.username, req.password)
    except ValueError as e:
        if str(e) == "username_taken":
            raise HTTPException(409, {"error": "username_taken"})
        raise

@app.post("/login")
def login(req: LoginRequest):
    try:
        return store.login(req.username, req.password)
    except ValueError:
        raise HTTPException(401, {"error": "invalid_credentials"})

@app.post("/send")
def send(req: SendRequest, x_session_id: str | None = Header(None)):
    username = auth(x_session_id)
    return store.send_message(username, req.to, req.text)

@app.get("/messages")
def messages(since: int = 0, x_session_id: str | None = Header(None)):
    username = auth(x_session_id)
    msgs = store.get_messages(username, since)
    server_ts = int(__import__("time").time() * 1000)
    return {"messages": msgs, "serverTimestamp": server_ts}

@app.get("/inbox")
def inbox(x_session_id: str | None = Header(None)):
    username = auth(x_session_id)
    return {"inbox": store.get_inbox(username)}

@app.get("/conversation/{other_user}")
def conversation(other_user: str, x_session_id: str | None = Header(None)):
    username = auth(x_session_id)
    msgs = store.get_conversation(username, other_user)
    return {"messages": msgs}

@app.post("/mark-read")
def mark_read(req: dict, x_session_id: str | None = Header(None)):
    username = auth(x_session_id)
    store.mark_read(req.get("fromUser", ""), username)
    return {}

@app.post("/logout")
def logout(x_session_id: str | None = Header(None)):
    auth(x_session_id)
    return {}

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from store import store

app = FastAPI()

class LoginRequest(BaseModel):
    username: str

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

@app.post("/login")
def login(req: LoginRequest):
    return store.login(req.username)

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

@app.post("/logout")
def logout(x_session_id: str | None = Header(None)):
    auth(x_session_id)
    return {}

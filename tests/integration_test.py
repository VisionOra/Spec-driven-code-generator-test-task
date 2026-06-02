import subprocess, time, threading, sys
from pathlib import Path

SERVER_URL = "http://localhost:8765"

class CLIClient:
    def __init__(self, lang: str, username: str):
        if lang == "swift":
            cmd = ["swift", "run", "messaging-cli",
                   "--user", username, "--server", SERVER_URL]
            cwd = Path("clients/swift")
        else:
            cmd = ["./gradlew", "run",
                   "--args", f"--user {username} --server {SERVER_URL}"]
            cwd = Path("clients/kotlin")

        self.username = username
        self.received = []
        self.states   = []
        self.proc = subprocess.Popen(
            cmd, cwd=cwd,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1
        )
        threading.Thread(target=self._read, daemon=True).start()
        time.sleep(5)  # wait for login + first poll

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if "RECEIVED" in line:
                self.received.append(line)
            if "STATE:" in line:
                self.states.append(line)

    def send(self, to: str, text: str):
        self.proc.stdin.write(f"send {to} {text}\n")
        self.proc.stdin.flush()

    def go_offline(self):
        self.proc.stdin.write("offline\n")
        self.proc.stdin.flush()
        time.sleep(0.5)

    def go_online(self):
        self.proc.stdin.write("online\n")
        self.proc.stdin.flush()
        time.sleep(0.5)

    def wait_for(self, text: str, timeout: int = 12) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if any(text in m for m in self.received):
                return True
            time.sleep(0.3)
        return False

    def stop(self):
        try:
            self.proc.stdin.write("quit\n")
            self.proc.stdin.flush()
        except:
            pass
        self.proc.terminate()


def scenario_a():
    print("--- Scenario A: Basic send/receive ---")
    alice = CLIClient("swift",  "alice_a")
    bob   = CLIClient("kotlin", "bob_a")

    alice.send("bob_a", "Hi Bob")
    assert bob.wait_for("Hi Bob"), "FAIL: Bob did not receive Alice's message"

    alice.stop(); bob.stop()
    print("PASS\n")


def scenario_b():
    print("--- Scenario B: Offline queue FIFO ---")
    alice = CLIClient("swift",  "alice_b")
    bob   = CLIClient("kotlin", "bob_b")

    alice.go_offline()
    alice.send("bob_b", "Message 1")
    alice.send("bob_b", "Message 2")
    time.sleep(2)

    assert not bob.wait_for("Message 1", timeout=3), \
        "FAIL: Message arrived while Alice was offline"

    alice.go_online()
    assert bob.wait_for("Message 1", timeout=12), "FAIL: Message 1 not delivered"
    assert bob.wait_for("Message 2", timeout=12), "FAIL: Message 2 not delivered"

    idx1 = next(i for i, m in enumerate(bob.received) if "Message 1" in m)
    idx2 = next(i for i, m in enumerate(bob.received) if "Message 2" in m)
    assert idx1 < idx2, "FAIL: Messages out of order"

    alice.stop(); bob.stop()
    print("PASS\n")


def scenario_c():
    print("--- Scenario C: Full Alice/Bob cross-platform ---")
    alice = CLIClient("swift",  "alice_c")
    bob   = CLIClient("kotlin", "bob_c")

    alice.send("bob_c", "Hi Bob, I have something important to tell you")
    assert bob.wait_for("important"), "FAIL: Bob did not receive Alice's first message"

    bob.send("alice_c", "What is it?")
    assert alice.wait_for("What is it"), "FAIL: Alice did not receive Bob's message"

    alice.go_offline()
    alice.send("bob_c", "It's about our trip")

    bob.go_offline()
    bob.send("alice_c", "I'm waiting")

    alice.go_online()
    assert bob.wait_for("our trip", timeout=12), \
        "FAIL: Alice's queued message not received"

    alice.go_offline()
    bob.go_online()
    assert alice.wait_for("waiting", timeout=12), \
        "FAIL: Bob's queued message not received"

    alice.stop(); bob.stop()
    print("PASS\n")


if __name__ == "__main__":
    scenario_a()
    scenario_b()
    scenario_c()
    print("✓ All scenarios passed")

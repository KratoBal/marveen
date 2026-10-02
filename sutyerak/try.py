#!/usr/bin/env python3
# ANSWERS: What does Sutyerák answer to a question, asked as a real logged-in employee (stage smoke account by default)?
"""Ask Sutyerák a question through the gateway, the way the OS will.

Logs in as an employee, mints that employee's ASSISTANT_READONLY token
(POST /auth/assistant-sessions), and posts the question to the gateway,
printing the streamed answer.

  python3 try.py "Hány nyitott munkalap van?" [--thread <id>] [--page /szerviz/munkalapok]

Env: TRY_API (default stage), TRY_EMAIL, TRY_PASSWORD_FILE, TRY_GATEWAY.
"""
import argparse
import datetime
import json
import os
import sys
import urllib.request

API = os.environ.get("TRY_API", "https://api-staging.acropora.hu")
EMAIL = os.environ.get("TRY_EMAIL", "flotta-smoke-raktar@acropora.hu")
PW_FILE = os.environ.get("TRY_PASSWORD_FILE", "/home/marveen/marveen/store/.stage-os-smoke-raktar-password")
GATEWAY = os.environ.get("TRY_GATEWAY", "http://127.0.0.1:3431")
SECRET = open("/home/marveen/marveen/store/.sutyerak-gateway-secret").read().strip()

ap = argparse.ArgumentParser()
ap.add_argument("question")
ap.add_argument("--thread")
ap.add_argument("--page")
ap.add_argument("--as-user-id", help="claim a different user id (to test thread isolation)")
a = ap.parse_args()


def call(method, url, body=None, token=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


# The OS caps live assistant tokens at 3 per employee (429 above that), and
# repeated logins look like an attack to the server's rate limiter. So the
# token is minted once and reused until a minute before it expires.
CACHE = "/home/marveen/sutyerak/try-token.json"
cached = None
try:
    with open(CACHE) as f:
        cached = json.load(f)
    if cached["api"] != API or cached["email"] != EMAIL or \
            datetime.datetime.fromisoformat(cached["expiresAt"].replace("Z", "+00:00")) - datetime.datetime.now(datetime.timezone.utc) < datetime.timedelta(seconds=60):
        cached = None
except (OSError, ValueError, KeyError):
    cached = None
if not cached:
    login = call("POST", API + "/auth/mobile/login/password", {"email": EMAIL, "password": open(PW_FILE).read().strip()})
    assistant = call("POST", API + "/auth/assistant-sessions", {}, login["token"])
    cached = {"api": API, "email": EMAIL, "token": assistant["token"], "expiresAt": assistant["expiresAt"], "user": login["user"]}
    fd = os.open(CACHE + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(cached, f)
    os.replace(CACHE + ".tmp", CACHE)
assistant = {"token": cached["token"]}
user = cached["user"]
body = {"token": assistant["token"], "user": {"id": a.as_user_id or user["id"], "name": user.get("name", "")},
        "question": a.question}
if a.thread:
    body["threadId"] = a.thread
if a.page:
    body["context"] = {"page": a.page}
req = urllib.request.Request(GATEWAY + "/ask", method="POST", data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json", "Authorization": "Bearer " + SECRET})
try:
    resp = urllib.request.urlopen(req, timeout=300)
except urllib.error.HTTPError as e:
    print("HTTP", e.code, e.read().decode())
    sys.exit(1)
for line in resp:
    ev = json.loads(line)
    if ev["type"] == "text":
        sys.stdout.write(ev["delta"])
        sys.stdout.flush()
    elif ev["type"] == "thread":
        print(f"[szal {ev['threadId']} {'uj' if ev['new'] else 'folytatva'}, {user.get('name')} / {user.get('role')}]")
    elif ev["type"] == "done":
        print(f"\n[kesz {ev['durationMs']} ms, {ev['toolCalls']} eszkozhivas]")
    else:
        print("\n", ev)

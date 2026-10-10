import asyncio
import re
import sqlite3
from typing import Literal
import hashlib
import json
import os
import secrets
import threading
import time
import uuid
from collections import defaultdict, deque
from pathlib import Path
from fastapi import FastAPI, HTTPException, Request, Depends, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from bank.crypto import canonical, unb64, public, private, sign, verify, seal, open_box, packet, check_packet
from bank.db import Database, password_hash

class Login(BaseModel):
    account: str = Field(max_length=100)
    password: str = Field(max_length=128)

class Signup(Login):
    name: str = Field(min_length=1, max_length=60)
    role: Literal['customer', 'merchant']

class Topup(BaseModel):
    request_id: str = Field(min_length=36, max_length=36)
    amount: int = Field(strict=True, ge=100, le=1000000)

class Registration(BaseModel):
    device_id: str = Field(min_length=16, max_length=80)
    sign_key: str = Field(max_length=64)
    box_key: str = Field(max_length=64)
    proof: str = Field(max_length=100)

def create_app(data_dir=None):
    db = Database(data_dir or os.getenv("KARO_DATA_DIR", "data"))
    key_path = db.directory / "bank-keys.json"
    if not key_path.exists():
        key_path.write_text(json.dumps({"sign": private(ed25519.Ed25519PrivateKey.generate()), "box": private(x25519.X25519PrivateKey.generate()), "mesh_id": secrets.token_hex(16)}))
        os.chmod(key_path, 0o600)
    keys = json.loads(key_path.read_text())
    signing = ed25519.Ed25519PrivateKey.from_private_bytes(unb64(keys["sign"]))
    encryption = x25519.X25519PrivateKey.from_private_bytes(unb64(keys["box"]))
    trust = {"sign_key": public(signing), "box_key": public(encryption), "mesh_id": keys["mesh_id"]}
    trust["fingerprint"] = hashlib.sha256(canonical(trust)).hexdigest()
    app = FastAPI(title="BeyondNet · Demo Bank", version="1.1.0")
    app.state.db = db
    app.state.trust = trust
    app.state.bank_online = True
    attempts = defaultdict(deque)
    rate_lock = threading.Lock()

    @app.middleware("http")
    async def limits(request, call_next):
        # Limit streamed bodies too; never trust only Content-Length.
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > 16384:
                return JSONResponse({"detail": "Request exceeds 16 KB"}, status_code=413)
        request._body = bytes(body)
        if request.url.path.startswith("/api/"):
            now = time.monotonic()
            key = (request.client.host if request.client else "unknown", request.url.path)
            with rate_lock:
                q = attempts[key]
                while q and q[0] < now - 60:
                    q.popleft()
                threshold = 12 if request.url.path in ("/api/login", "/api/signup") else 240
                if len(q) >= threshold:
                    return JSONResponse({"detail": "Too many requests; retry in a minute"}, status_code=429)
                q.append(now)
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Cache-Control"] = "no-store"
        return response

    def account(request: Request):
        token = request.headers.get("Authorization", "").removeprefix("Bearer ")
        with db.connect() as c:
            row = c.execute("SELECT account FROM sessions WHERE token=? AND expiry>?", (token, int(time.time()))).fetchone()
        if not row:
            raise HTTPException(401, "Sign in online again; your session has expired")
        return row["account"]

    def admin(request: Request):
        token = request.headers.get("Authorization", "").removeprefix("Bearer ")
        if not secrets.compare_digest(token, db.admin_token):
            raise HTTPException(401, "Bank operator key required")

    def merchant(c):
        return [json.loads(x["certificate"]) for x in c.execute("SELECT d.certificate FROM devices d JOIN accounts a ON a.id=d.account WHERE a.role='merchant' AND d.revoked=0")]

    @app.get("/api/health")
    def health():
        return {"service": "BeyondNet demo bank", "online": app.state.bank_online, **trust}

    @app.post("/api/login")
    def login(body: Login):
        with db.connect() as c:
            a = c.execute("SELECT * FROM accounts WHERE id=?", (body.account.strip().lower(),)).fetchone()
            if not a or not secrets.compare_digest(password_hash(body.password, a["salt"]), a["password"]):
                raise HTTPException(401, "Account or demo password is incorrect")
            token = secrets.token_urlsafe(32)
            expiry = int(time.time()) + 7 * 86400
            c.execute("DELETE FROM sessions WHERE expiry<?", (int(time.time()),))
            c.execute("INSERT INTO sessions VALUES(?,?,?)", (token, a["id"], expiry))
            return {"token": token, "session_expires_at": expiry, "account": {**{k: a[k] for k in ("id", "name", "role", "balance")}, "revision": c.execute("SELECT COALESCE(MAX(id),0) FROM ledger WHERE account=?", (a["id"],)).fetchone()[0]}, "trust": trust}

    def snapshot(c, aid):
        a = c.execute("SELECT id,name,role,balance FROM accounts WHERE id=?", (aid,)).fetchone()
        return {**dict(a), "revision": c.execute("SELECT COALESCE(MAX(id),0) FROM ledger WHERE account=?", (aid,)).fetchone()[0]}

    @app.post("/api/signup")
    def signup(body: Signup):
        aid = body.account.strip().lower()
        name = body.name.strip()
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{2,31}@beyondnet", aid):
            raise HTTPException(400, "Use 3–32 letters, digits, dots, underscores or hyphens followed by @beyondnet")
        if len(body.password) < 8 or not name:
            raise HTTPException(400, "Enter a name and a password of at least 8 characters")
        salt = secrets.token_bytes(16)
        try:
            with db.connect() as c:
                c.execute("INSERT INTO accounts VALUES(?,?,?,?,?,?)", (aid, name, body.role, 0, salt, password_hash(body.password, salt)))
                db.event(c, "account_created", {"account": aid, "role": body.role})
        except sqlite3.IntegrityError:
            raise HTTPException(409, "This payment ID is already taken. Sign in or choose another ID")
        return login(Login(account=aid, password=body.password))

    @app.post("/api/topups")
    def topup(body: Topup, aid=Depends(account)):
        try:
            uuid.UUID(body.request_id)
        except ValueError:
            raise HTTPException(400, "Invalid top-up request ID")
        if not app.state.bank_online:
            raise HTTPException(503, "Demo bank is paused; retry this top-up later")
        with db.connect() as c:
            c.execute("BEGIN IMMEDIATE")
            old = c.execute("SELECT * FROM topups WHERE account=? AND request_id=?", (aid, body.request_id)).fetchone()
            if old:
                if old['amount'] != body.amount:
                    raise HTTPException(409, "Top-up ID already used with a different amount")
                return {"account": snapshot(c, aid), "reference": old['reference'], "duplicate": True}
            current = snapshot(c, aid)
            balance = current['balance'] + body.amount
            if balance > 100000000:
                raise HTTPException(400, "Demo balance limit is ₹10,00,000")
            ref = "DEMO-" + uuid.uuid4().hex[:16].upper()
            now = int(time.time())
            c.execute("UPDATE accounts SET balance=? WHERE id=?", (balance, aid))
            # The synthetic funding account offsets minted demo credits; never real money.
            reserve = c.execute("SELECT COALESCE(SUM(delta),0) FROM ledger WHERE account='demo-funding'").fetchone()[0] - body.amount
            for acc, delta, after in [('demo-funding', -body.amount, reserve), (aid, body.amount, balance)]:
                c.execute("INSERT INTO ledger(payment,account,delta,balance_after,committed) VALUES(?,?,?,?,?)", (ref, acc, delta, after, now))
            c.execute("INSERT INTO topups VALUES(?,?,?,?)", (aid, body.request_id, body.amount, ref))
            db.event(c, "demo_money_added", {"account": aid, "amount": body.amount, "reference": ref})
            return {"account": snapshot(c, aid), "reference": ref, "duplicate": False}

    @app.get("/api/recipients/{payment_id}")
    def recipient(payment_id: str, aid=Depends(account)):
        with db.connect() as c:
            rows = c.execute("SELECT certificate FROM devices WHERE account=? AND revoked=0 ORDER BY rowid DESC", (payment_id.strip().lower(),))
            for row in rows:
                cert = json.loads(row[0])
                if cert['body']['expires_at'] > int(time.time()):
                    return {"certificate": cert}
        raise HTTPException(404, "Recipient not found. Ask them to sign up and enroll their device")

    @app.post("/api/devices")
    def register(body: Registration, aid=Depends(account)):
        try:
            if len(unb64(body.sign_key)) != 32 or len(unb64(body.box_key)) != 32:
                raise ValueError()
            verify(body.sign_key, {"body": {"device_id": body.device_id, "account_id": aid, "sign_key": body.sign_key, "box_key": body.box_key}, "signature": body.proof})
        except Exception:
            raise HTTPException(400, "Invalid device keys or proof")
        with db.connect() as c:
            owner = c.execute("SELECT name,role FROM accounts WHERE id=?", (aid,)).fetchone()
        certificate = sign(signing, {"display_name": owner["name"], "role": owner["role"], "device_id": body.device_id, "account_id": aid, "sign_key": body.sign_key, "box_key": body.box_key, "mesh_id": keys["mesh_id"], "expires_at": int(time.time()) + 30 * 86400})
        with db.connect() as c:
            old = c.execute("SELECT * FROM devices WHERE id=? OR sign_key=?", (body.device_id, body.sign_key)).fetchone()
            if old and (old["account"] != aid or old["id"] != body.device_id or old["sign_key"] != body.sign_key or old["box_key"] != body.box_key or old["revoked"]):
                raise HTTPException(409, "Device key already registered or revoked")
            if not old and c.execute("SELECT COUNT(*) FROM devices WHERE account=? AND revoked=0", (aid,)).fetchone()[0] >= 8:
                raise HTTPException(409, "Demo account device limit reached; revoke an old device first")
            c.execute("INSERT INTO devices VALUES(?,?,?,?,?,0) ON CONFLICT(id) DO UPDATE SET certificate=excluded.certificate", (body.device_id, aid, body.sign_key, body.box_key, json.dumps(certificate)))
            db.event(c, "device_enrolled", {"account": aid, "device_id": body.device_id})
            return {"certificate": certificate, "merchants": merchant(c)}

    @app.get("/api/me")
    def me(aid=Depends(account)):
        with db.connect() as c:
            a = c.execute("SELECT id,name,role,balance FROM accounts WHERE id=?", (aid,)).fetchone()
            return {"account": {**dict(a), "revision": c.execute("SELECT COALESCE(MAX(id),0) FROM ledger WHERE account=?", (aid,)).fetchone()[0]}, "merchants": merchant(c)}

    @app.post("/api/packets")
    def ingest(p: dict, aid=Depends(account)):
        if not app.state.bank_online:
            raise HTTPException(503, "Demo bank connection paused; retain request and retry")
        now = int(time.time())
        try:
            check_packet(p)
            if p["kind"] != "payment":
                raise ValueError("Only payment instructions are submitted to the bank")
            signed = open_box(encryption, p["box"])
            body = signed["body"]
            required = {"v", "payment_id", "sender", "recipient", "amount", "currency", "created_at", "expires_at", "device_id", "sender_mailbox", "recipient_mailbox"}
            if set(body) != required or body["v"] != 1:
                raise ValueError("Unsupported payment instruction")
            if type(body["amount"]) is not int or not 1 <= body["amount"] <= 1000000 or body["currency"] != "INR":
                raise ValueError("Invalid amount or currency")
            if not all(isinstance(body[k], str) and len(body[k]) <= 100 for k in ("payment_id", "sender", "recipient", "device_id", "sender_mailbox", "recipient_mailbox")):
                raise ValueError("Invalid identifiers")
            uuid.UUID(body["payment_id"])
            if any(len(body[k]) < 32 for k in ("sender_mailbox", "recipient_mailbox")) or body["sender_mailbox"] == body["recipient_mailbox"]:
                raise ValueError("Invalid receipt routing capabilities")
            if type(body["created_at"]) is not int or type(body["expires_at"]) is not int or not 0 < body["expires_at"] - body["created_at"] <= 900:
                raise ValueError("Invalid authorization window")
            with db.connect() as c:
                d = c.execute("SELECT * FROM devices WHERE id=? AND account=? AND revoked=0", (body["device_id"], body["sender"])).fetchone()
                if not d:
                    raise ValueError("Unknown or revoked sender device")
                verify(d["sign_key"], signed)
            if p["mailbox"] != body["sender_mailbox"] or p["expires_at"] != body["expires_at"]:
                raise ValueError("Envelope does not match signed instruction")
        except Exception as e:
            raise HTTPException(400, f"Payment validation failed: {type(e).__name__}")
        request_hash = hashlib.sha256(canonical(body)).hexdigest()
        with db.connect() as c:
            # SQLite's single writer serializes this entire claim/balance/ledger/receipt transaction.
            c.execute("BEGIN IMMEDIATE")
            existing = c.execute("SELECT * FROM payments WHERE sender=? AND id=?", (body["sender"], body["payment_id"])).fetchone()
            if existing:
                if existing["hash"] != request_hash:
                    raise HTTPException(409, "Payment ID was already used for a different instruction")
                receipts = json.loads(existing["receipts"])
                db.event(c, "duplicate_recovered", {"payment_id": body["payment_id"], "status": existing["status"]})
                return {"duplicate": True, "receipts": receipts}
            d = c.execute("SELECT * FROM devices WHERE id=? AND revoked=0", (body["device_id"],)).fetchone()
            if not d:
                raise HTTPException(400, "Sender device was revoked")
            sender = c.execute("SELECT * FROM accounts WHERE id=?", (body["sender"],)).fetchone()
            recipient = c.execute("SELECT * FROM accounts WHERE id=?", (body["recipient"],)).fetchone()
            recipient_devices = list(c.execute("SELECT * FROM devices WHERE account=? AND revoked=0", (body["recipient"],)))
            if not sender or not recipient or not recipient_devices or body["sender"] == body["recipient"]:
                raise HTTPException(400, "Recipient must be a different enrolled account")
            reason = ""
            if body["created_at"] > now + 60:
                reason = "Device clock is ahead of the bank"
            elif body["expires_at"] < now:
                reason = "Authorization expired before bank submission"
            elif sender["balance"] < body["amount"]:
                reason = "Insufficient demo balance"
            status = "rejected" if reason else "paid"
            bank_ref = "OK-" + uuid.uuid4().hex[:16].upper()
            if status == "paid":
                for acc, delta in ((sender, -body["amount"]), (recipient, body["amount"])):
                    balance = acc["balance"] + delta
                    c.execute("UPDATE accounts SET balance=? WHERE id=?", (balance, acc["id"]))
                    c.execute("INSERT INTO ledger(payment,account,delta,balance_after,committed) VALUES(?,?,?,?,?)", (bank_ref, acc["id"], delta, balance, now))
            receipts = []
            for device, capability in [(d, body["sender_mailbox"])] + [(x, body["recipient_mailbox"]) for x in recipient_devices]:
                balance = c.execute("SELECT balance FROM accounts WHERE id=?", (device["account"],)).fetchone()[0]
                result = sign(signing, {"v": 1, "payment_id": body["payment_id"], "sender": body["sender"], "recipient": body["recipient"], "amount": body["amount"], "currency": "INR", "status": status, "reason": reason, "bank_ref": bank_ref, "committed_at": now, "device_id": device["id"], "balance": balance, "balance_revision": c.execute("SELECT COALESCE(MAX(id),0) FROM ledger WHERE account=?", (device["account"],)).fetchone()[0]})
                receipt = packet("receipt", seal(device["box_key"], result), capability, now + 7 * 86400, list(reversed(p["path"])))
                receipts.append(receipt)
                c.execute("INSERT INTO device_receipts(device,packet_id,packet,expiry) VALUES(?,?,?,?)", (device['id'], receipt['id'], json.dumps(receipt), receipt['expires_at']))
            encoded = json.dumps(receipts)
            c.execute("INSERT INTO payments VALUES(?,?,?,?,?,?,?,?,?,?)", (body["sender"], body["payment_id"], request_hash, body["recipient"], body["amount"], status, reason, bank_ref, now, encoded))
            for cap in (body["sender_mailbox"], body["recipient_mailbox"]):
                owned = receipts if cap == body["sender_mailbox"] else [x for x in receipts if x["mailbox"] == cap]
                c.execute("INSERT INTO mailboxes VALUES(?,?,?) ON CONFLICT(capability) DO UPDATE SET receipts=excluded.receipts,expiry=excluded.expiry", (cap, json.dumps(owned), now + 7 * 86400))
            db.event(c, "bank_decision", {"payment_id": body["payment_id"], "sender": body["sender"], "recipient": body["recipient"], "amount": body["amount"], "status": status, "reason": reason, "bank_ref": bank_ref})
        return {"duplicate": False, "receipts": receipts}

    @app.get("/api/mailbox/{capability}")
    def mailbox(capability: str, aid=Depends(account)):
        with db.connect() as c:
            r = c.execute("SELECT receipts FROM mailboxes WHERE capability=? AND expiry>?", (capability, int(time.time()))).fetchone()
            return {"receipts": json.loads(r[0]) if r else []}

    def check_device(c, aid, did):
        if not c.execute("SELECT 1 FROM devices WHERE id=? AND account=? AND revoked=0", (did, aid)).fetchone():
            raise HTTPException(403, "Device is not registered or has been revoked")

    def inbox(aid, did, after=0):
        with db.connect() as c:
            check_device(c, aid, did)
            rows = list(c.execute("SELECT seq,packet FROM device_receipts WHERE device=? AND seq>? AND expiry>? ORDER BY seq LIMIT 50", (did, after, int(time.time()))))
        return {"receipts": [json.loads(r['packet']) for r in rows], "cursor": rows[-1]['seq'] if rows else after}

    @app.get("/api/receipts/{device_id}")
    def own_receipts(device_id: str, after: int = 0, aid=Depends(account)):
        return inbox(aid, device_id, max(0, after))

    @app.websocket("/api/live")
    async def live(ws: WebSocket):
        await ws.accept()
        try:
            # Credentials are carried in the first TLS-protected frame, never a URL.
            raw = await asyncio.wait_for(ws.receive_text(), timeout=10)
            if len(raw) > 4096:
                await ws.close(code=1009)
                return
            auth = json.loads(raw)
            token, did = auth.get('token', ''), auth.get('device_id', '')
            if not isinstance(token, str) or not isinstance(did, str):
                await ws.close(code=1008)
                return
            with db.connect() as c:
                row = c.execute("SELECT account FROM sessions WHERE token=? AND expiry>?", (token, int(time.time()))).fetchone()
                if not row:
                    await ws.close(code=1008)
                    return
                aid = row['account']
                check_device(c, aid, did)
            cursor = 0
            await ws.send_json({"type": "ready", "fingerprint": trust['fingerprint']})
            window, count = time.monotonic(), 0
            revision = -1
            while True:
                with db.connect() as c:
                    if not c.execute("SELECT 1 FROM sessions WHERE token=? AND expiry>?", (token, int(time.time()))).fetchone():
                        await ws.close(code=1008)
                        return
                    check_device(c, aid, did)
                    current = snapshot(c, aid)
                if current['revision'] != revision:
                    await ws.send_json({"type": "account", "account": current})
                    revision = current['revision']
                batch = await run_in_threadpool(inbox, aid, did, cursor)
                if batch['receipts']:
                    await ws.send_json({"type": "receipts", **batch})
                    cursor = batch['cursor']
                try:
                    raw = await asyncio.wait_for(ws.receive_text(), timeout=1)
                except asyncio.TimeoutError:
                    continue
                if len(raw) > 16384:
                    await ws.close(code=1009)
                    return
                if time.monotonic() - window >= 60:
                    window, count = time.monotonic(), 0
                count += 1
                if count > 120:
                    await ws.close(code=1008)
                    return
                message = json.loads(raw)
                rid = message.get('id')
                if message.get('type') != 'submit' or not isinstance(rid, str) or len(rid) > 80 or not isinstance(message.get('packet'), dict):
                    await ws.close(code=1008)
                    return
                try:
                    result = await run_in_threadpool(ingest, message['packet'], aid)
                    await ws.send_json({"type": "result", "id": rid, **result})
                except HTTPException as exc:
                    await ws.send_json({"type": "error", "id": rid, "status": exc.status_code, "message": exc.detail})
        except (WebSocketDisconnect, asyncio.TimeoutError):
            pass
        except (ValueError, TypeError, AttributeError, HTTPException):
            await ws.close(code=1008)

    @app.get("/api/admin/state", dependencies=[Depends(admin)])
    def state():
        with db.connect() as c:
            return {"online": app.state.bank_online, "trust": trust,
                    "metrics": {"paid_count": c.execute("SELECT COUNT(*) FROM payments WHERE status='paid'").fetchone()[0], "volume": c.execute("SELECT COALESCE(SUM(amount),0) FROM payments WHERE status='paid'").fetchone()[0]},
                    "accounts": [dict(x) for x in c.execute("SELECT id,name,role,balance FROM accounts")],
                    "devices": [dict(x) for x in c.execute("SELECT id,account,revoked FROM devices")],
                    "payments": [dict(x) for x in c.execute("SELECT id,sender,recipient,amount,status,reason,bank_ref,committed FROM payments ORDER BY committed DESC LIMIT 60")],
                    "ledger": [dict(x) for x in c.execute("SELECT * FROM ledger ORDER BY id DESC LIMIT 120")],
                    "events": [{**dict(x), "detail": json.loads(x["detail"])} for x in c.execute("SELECT * FROM events ORDER BY id DESC LIMIT 100")]}

    @app.post("/api/admin/connection", dependencies=[Depends(admin)])
    def connection(body: dict):
        if type(body.get("online")) is not bool:
            raise HTTPException(400, "online must be a boolean")
        app.state.bank_online = body["online"]
        return {"online": app.state.bank_online}

    @app.post("/api/admin/revoke/{device_id}", dependencies=[Depends(admin)])
    def revoke(device_id: str):
        with db.connect() as c:
            c.execute("UPDATE devices SET revoked=1 WHERE id=?", (device_id,))
            db.event(c, "device_revoked", {"device_id": device_id})
        return {"revoked": True}

    @app.post("/api/admin/rehearsal", dependencies=[Depends(admin)])
    def rehearsal():
        from bank.demo import rehearse
        return rehearse(app)

    static = Path(__file__).parent / "static"
    app.mount("/static", StaticFiles(directory=static), name="static")
    @app.get("/", include_in_schema=False)
    def dashboard():
        return FileResponse(static / "index.html")
    return app

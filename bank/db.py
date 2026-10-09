import hashlib
import os
import secrets
import sqlite3
import time
from pathlib import Path
from contextlib import contextmanager

DEMO_ACCOUNTS = [
    ("alice@karo", "Aanya Sharma", "customer", 100000, "alice-demo-pass"),
    ("relay@karo", "Relay Phone", "customer", 0, "relay-demo-pass"),
    ("gateway@karo", "Gateway Phone", "customer", 0, "gateway-demo-pass"),
    ("chai@karo", "Chai & Co.", "merchant", 25000, "chai-demo-pass"),
]

def password_hash(password, salt):
    return hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1).hex()

class Database:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        self.path = self.directory / "bank.sqlite3"
        with self.connect() as c:
            c.executescript('''
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS accounts (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL,
                balance INTEGER NOT NULL CHECK(balance >= 0), salt BLOB NOT NULL, password TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS sessions (token TEXT PRIMARY KEY, account TEXT NOT NULL, expiry INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY, account TEXT NOT NULL REFERENCES accounts(id),
                sign_key TEXT NOT NULL UNIQUE, box_key TEXT NOT NULL, certificate TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS payments (
                sender TEXT NOT NULL, id TEXT NOT NULL, hash TEXT NOT NULL, recipient TEXT NOT NULL,
                amount INTEGER NOT NULL, status TEXT NOT NULL, reason TEXT NOT NULL, bank_ref TEXT NOT NULL,
                committed INTEGER NOT NULL, receipts TEXT NOT NULL, PRIMARY KEY(sender,id));
            CREATE TABLE IF NOT EXISTS ledger (
                id INTEGER PRIMARY KEY AUTOINCREMENT, payment TEXT NOT NULL, account TEXT NOT NULL,
                delta INTEGER NOT NULL, balance_after INTEGER NOT NULL, committed INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS mailboxes (capability TEXT PRIMARY KEY, receipts TEXT NOT NULL, expiry INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS topups (
                account TEXT NOT NULL, request_id TEXT NOT NULL, amount INTEGER NOT NULL,
                reference TEXT NOT NULL, PRIMARY KEY(account,request_id));
            CREATE TABLE IF NOT EXISTS device_receipts (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, device TEXT NOT NULL,
                packet_id TEXT NOT NULL UNIQUE, packet TEXT NOT NULL, expiry INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS receipt_device ON device_receipts(device,seq);
            CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL);
            ''')
            for account, name, role, balance, password in DEMO_ACCOUNTS:
                if not c.execute("SELECT 1 FROM accounts WHERE id=?", (account,)).fetchone():
                    salt = secrets.token_bytes(16)
                    c.execute("INSERT INTO accounts VALUES(?,?,?,?,?,?)", (account, name, role, balance, salt, password_hash(password, salt)))
            c.execute("UPDATE accounts SET role='customer' WHERE role='relay'")
        token_path = self.directory / "admin-token.txt"
        if not token_path.exists():
            token_path.write_text(secrets.token_urlsafe(32))
            os.chmod(token_path, 0o600)
        self.admin_token = token_path.read_text().strip()

    @contextmanager
    def connect(self):
        c = sqlite3.connect(self.path, timeout=20)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA foreign_keys=ON")
        try:
            yield c
            c.commit()
        except BaseException:
            c.rollback()
            raise
        finally:
            c.close()

    def event(self, c, kind, detail):
        import json
        c.execute("INSERT INTO events(at,kind,detail) VALUES(?,?,?)", (int(time.time()), kind, json.dumps(detail)))

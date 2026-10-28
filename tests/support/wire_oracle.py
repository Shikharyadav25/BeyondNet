"""Independent Python test oracle for Java/Dart wire bytes. Not a bank server or production dependency."""
import base64
import hashlib
import json
import os
import re
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

DOMAIN = b"offline-karo/box/v1"

def canonical(value):
    # Java/Dart order keys by UTF-16 code units. Preserve the existing wire
    # bytes, including for supplementary Unicode keys in interoperability tests.
    def ordered(item):
        if isinstance(item, dict):
            return {key: ordered(item[key]) for key in sorted(item, key=lambda key: key.encode('utf-16-be'))}
        if isinstance(item, list):
            return [ordered(child) for child in item]
        if isinstance(item, float):
            raise ValueError('Floats are not wire values')
        return item
    return json.dumps(ordered(value), separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()

def b64(value):
    return base64.b64encode(value).decode()

def unb64(value):
    return base64.b64decode(value, validate=True)

def public(key):
    return b64(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))

def private(key):
    return b64(key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()))

def sign(key, body):
    return {"body": body, "signature": b64(key.sign(canonical(body)))}

def verify(public_key, signed):
    ed25519.Ed25519PublicKey.from_public_bytes(unb64(public_key)).verify(unb64(signed["signature"]), canonical(signed["body"]))
    return signed["body"]

def seal(public_key, value):
    ephemeral = x25519.X25519PrivateKey.generate()
    peer = x25519.X25519PublicKey.from_public_bytes(unb64(public_key))
    shared = ephemeral.exchange(peer)
    ep = unb64(public(ephemeral))
    recipient = unb64(public_key)
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=ep + recipient, info=DOMAIN).derive(shared)
    nonce = os.urandom(12)
    return {"ephemeral": b64(ep), "nonce": b64(nonce), "ciphertext": b64(AESGCM(key).encrypt(nonce, canonical(value), DOMAIN))}

def open_box(key, box):
    ep = unb64(box["ephemeral"])
    shared = key.exchange(x25519.X25519PublicKey.from_public_bytes(ep))
    secret = HKDF(algorithm=hashes.SHA256(), length=32, salt=ep + unb64(public(key)), info=DOMAIN).derive(shared)
    return json.loads(AESGCM(secret).decrypt(unb64(box["nonce"]), unb64(box["ciphertext"]), DOMAIN))

def packet(kind, box, mailbox, expires_at, path=None):
    core = {"v": 1, "kind": kind, "mailbox": mailbox, "box": box, "expires_at": expires_at}
    return {**core, "id": hashlib.sha256(canonical(core)).hexdigest(), "hops": 0, "path": path or []}

def check_packet(p):
    if len(canonical(p)) > 8192 or p.get("v") != 1 or p.get("kind") not in ("payment", "receipt"):
        raise ValueError("Unsupported or oversized packet")
    core = {k: p[k] for k in ("v", "kind", "mailbox", "box", "expires_at")}
    if hashlib.sha256(canonical(core)).hexdigest() != p.get("id"):
        raise ValueError("Packet integrity mismatch")
    if type(p.get("hops")) is not int or not 0 <= p["hops"] <= 4:
        raise ValueError("Hop budget exceeded")
    for field, maximum in [('path', 8), ('trail', 4)]:
        route = p.get(field)
        if field == 'trail' and route is None:
            continue
        if not isinstance(route, list) or len(route) > maximum or any(not isinstance(x, str) or not x or len(x.encode('utf-16-be')) // 2 > 80 for x in route) or len(set(route)) != len(route) or (field == 'trail' and len(route) > p['hops']):
            raise ValueError('Invalid routing history')
    if not isinstance(p["mailbox"], str) or not re.fullmatch(r'[0-9a-fA-F]{32,100}', p['mailbox']):
        raise ValueError("Invalid mailbox capability")
    if type(p["expires_at"]) is not int:
        raise ValueError("Invalid expiry")

# Wire protocol v1

Implementation: `mobile/lib/protocol.dart`, `mobile/lib/ble_transport.dart`, `mobile/lib/engine.dart`, and `backend/src/main/java/com/beyondnet/bank/WireCrypto.java`. Test vectors in `mobile/test/fixtures` contain **public test-only private keys**, not bank or user credentials.

## Canonical representation

Canonical JSON uses UTF-8, recursively sorted object keys, no insignificant whitespace, ordinary JSON booleans/null, and unescaped Unicode. All financial amounts are integer paise; timestamps are integer Unix seconds. Floats are not part of the protocol. Binary values use standard padded Base64. Packet IDs use lowercase hexadecimal SHA-256.

Signed objects are `{ "body": <object>, "signature": <base64 Ed25519 signature> }`. Only canonical `body` bytes are signed. Cross-language tests compare deterministic signatures as well as encryption/decryption in both directions.

## Encryption envelope

This is an explicit versioned hybrid encryption construction, not an HPKE implementation or a claim of HPKE compliance.

1. Generate a fresh ephemeral X25519 keypair per envelope.
2. Compute X25519 shared secret with the recipient’s registered X25519 public key.
3. Derive 32 bytes using HKDF-SHA256. Salt is raw `ephemeral_public || recipient_public` (64 bytes); info is UTF-8 `offline-karo/box/v1`.
4. Encrypt canonical signed-object bytes with AES-256-GCM, a fresh 12-byte nonce, and additional authenticated data `offline-karo/box/v1`.
5. Encode `{ephemeral, nonce, ciphertext}`, where ciphertext is encrypted bytes followed by the 16-byte GCM tag.

Each payment goes to the bank’s public encryption key. Each receipt is separately encrypted to a registered sender or recipient device. Device and bank private keys never travel through relays.

## Packet

```json
{
  "v": 1,
  "kind": "payment",
  "mailbox": "48-character-random-capability",
  "box": {"ephemeral":"…", "nonce":"…", "ciphertext":"…"},
  "expires_at": 2000000000,
  "id": "sha256-of-immutable-core",
  "hops": 0,
  "path": []
}
```

The immutable core consists of `v`, `kind`, `mailbox`, `box`, and `expires_at`. The packet ID hashes that core. `hops` and `path` are mutable advisory metadata, not financial authorization. Packet size is at most 8,192 canonical bytes, hop count is 0–4, and path length is at most 8. The phone store also has a 10 MiB / 1,000-packet cap.

A payment forward increments hop count and appends the forwarding device ID if absent. The bank seeds each receipt with the reverse request path and a fresh zero hop count. Relays prioritize return receipts toward peers on that path, then replicate through other permitted peers. Receipt `path` is advisory; no trusted location or anonymous routing claim is made.

## Signed payment instruction

| Field | Meaning |
|---|---|
| `v` | 2 (payment body); envelope and receipts remain v1 |
| `payment_id` | UUID; reused on every retry |
| `sender`, `recipient` | Demo bank account IDs |
| `amount` | Integer paise, 1–1,000,000 |
| `currency` | INR |
| `created_at`, `expires_at` | Authorization window, at most 600 seconds |
| `device_id` | Registered signing device |
| `pin` | Six numeric digits inside bank-encrypted signed body; never stored in plaintext |
| `sender_mailbox`, `recipient_mailbox` | Separate cryptographically random receipt capabilities |

The bank verifies the sender/device binding, signature, exact field set, ID, amount/currency, authorization window, and envelope agreement. It hashes the signed body for idempotency. The sender mailbox and expiry in the outer envelope must match the signed inner values. The original encrypted payload is not re-signed by relays.

The recipient QR contains a signed device identity; this version uses sender-entered amounts, not signed invoices. Never confuse it with a real UPI QR.

## Signed receipt

Receipt bodies contain version, payment ID, parties, amount, currency, `paid` or `rejected`, reason, bank reference, commit time, addressed device ID, confirmed account balance, and `balance_revision`.

The phone decrypts using its device key, verifies the pinned bank signature, validates the addressed device and account, and matches parties/amount against its original intent. The balance revision orders balance snapshots even when two receipts share the same commit second. Signed results are persisted. Startup retries local delivery of retained receipt ciphertext if a previous run stopped between persistence and UI updates.

## HTTPS API

Phone enrollment and gateway requests use HTTPS. The laptop service itself defaults to loopback HTTP, intended to sit behind a trusted TLS tunnel or reverse proxy. Phone clients reject cleartext origins.

- `GET /api/health`: service state and public trust keys/fingerprint.
- `POST /api/login`: demo credentials → seven-day bearer session and account snapshot.
- `POST /api/devices`: authenticated key registration with proof of possession → signed device certificate.
- `GET /api/me`: authenticated account snapshot and enrolled merchant certificates.
- `POST /api/packets`: authenticated gateway submits one payment packet → stored encrypted receipts. The gateway need not own the payment.
- `GET /api/mailbox/{capability}`: authenticated retrieval of a payment’s encrypted response bundle. Sender capability returns the bundle needed for recovery; recipient capability returns recipient packets. Unknown/expired capabilities return an empty list. There is no unrestricted phone endpoint listing payment mailboxes.
- `/api/admin/*`: separate operator bearer token; dashboard state, submission pause/resume, device revocation, and software rehearsal.

Request bodies are capped at 16 KiB. Login is limited to 12 requests/minute per observed client IP; other API paths to 240/minute. The local server does not trust forwarded IP headers. Behind a loopback tunnel this becomes a shared demo rate limit, which is intentional for the small test.

## BLE GATT

Service UUID: `f953c610-4f9e-4ac8-a6d6-6f666b61726f`.

Read/write characteristic UUID: `f953c611-4f9e-4ac8-a6d6-6f666b61726f`.

Phones advertise and scan for this service. A central establishes a short connection, discovers the characteristic, exchanges messages, then disconnects. Either direction can initiate. No OS-level manual pairing is required; application messages authenticate against bank-issued certificates.

Messages are canonical JSON, bounded at 12,288 bytes. Each ATT write/read carries at most 20 bytes:

- Byte 0: flags, bit 0 = start of message, bit 1 = end of message.
- Bytes 1–19: payload.
- `[0]` alone during response reads = not ready; poll briefly.

Start resets partial assembly. A continuation without a start, oversized frame, or oversized aggregate is rejected. Completed requests are verified and handled before the signed application response is made available. Write acknowledgment only confirms transport handling. A signed `stored` response follows successful database persistence.

Responses use small reads below the minimum MTU’s long-read threshold. The central serializes writes and reads on a connection, applies timeouts, and disconnects on failure. Peripheral partial sessions are bounded and cleaned after inactivity. An interrupted transfer starts again from the beginning; packet deduplication makes retransmission safe.

## Authenticated peer commands

A peer message contains a bank-signed certificate plus an Ed25519-signed body with fresh UUID `request_id`, `at` Unix seconds, and a command. Responses echo the request ID and are verified against the enrolled peer. Clocks must be within two minutes. Recently seen request IDs reject replay in the current session. This authenticates commands; it is not BLE link encryption or a general-purpose secure transport.

Commands:

| Command | Response / effect |
|---|---|
| `inventory`, `offset` | At most 48 sorted active packet IDs and a next cursor; bounded by the store cap |
| `get`, `id` | Eligible packet with incremented forwarding metadata, or `missing` |
| `put`, `packet` | Validate, persist, attempt local delivery; then signed `stored` acknowledgment |

Sync exchanges inventories, pulls up to eight missing packets, and pushes up to eight missing packets per connection. Every five seconds the foreground engine considers another round. Successful peers have a cooldown; failures back off up to 60 seconds. Gateway retries similarly back off. The original request remains available for idempotent recovery.

## Retention

- New payment authorization: 10 minutes (600 seconds); saved legacy decisions remain recoverable.
- Receipt propagation: 7 days from bank decision.
- Expired packet cache: retained for a further 7 days for recovery, bounded by storage capacity.
- Own intent and receipt history: retained until app data is removed.
- Device certificates: 30 days; renewal is online.
- Login sessions: 7 days; renewal is online.

Expiry is not a financial rejection unless the bank signs that decision. If no receipt arrives, the outcome remains unknown.

## Online and discovery endpoints

`POST /api/signup`: account, name, password, role (`customer` or `merchant`). `POST /api/topups`: integer paise amount (100–1,000,000) plus UUID request_id; authenticated, account-scoped idempotency. `GET /api/recipients/{payment_id}` returns an active bank-signed certificate.

WSS `/api/live` first frame: `{token, device_id}`. Server replies `{type: ready, fingerprint}`. Submit `{type: submit, id, packet}`; receive `{type: result, id, duplicate, receipts}` or `{type: error, id, status, message}`. Server also emits `{type: account, account}` and `{type: receipts, receipts, cursor}`. Inbox receipts are durable and replayed on reconnect; local packet IDs deduplicate repeats. `GET /api/receipts/{device_id}?after=cursor` provides authenticated owner-only HTTP recovery. Existing mailbox recovery is retained for relays. The envelope and receipt formats are retained; current new payment bodies require v2 with an encrypted demo PIN.

Live frames are capped at 16 KiB (authentication 4 KiB), 120 client messages/minute/connection, ten seconds to authenticate. Signup/login are limited to 12/minute per observed IP. The proxy must support WebSocket upgrades; production app endpoints are HTTPS/WSS only.

BLE inventory responses add an advisory `online` boolean. `resolve` with `account_id` asks a connected peer for a cached certificate or an online bank lookup; response is `{op: recipient, certificate}` (null if unknown). The recipient certificate is verified independently against bank trust. This lookup does not recursively traverse arbitrary relays; scan QR if the ID cannot be resolved. Older peers can still exchange payment packets but may not support ID resolution.


## Java 1.2.0 authorization and storage

`POST /api/pin` requires an account session and `{password,pin}` to set/reset a six-digit demo PIN. Account snapshots include `pin_configured`. Five distinct incorrect PIN requests temporarily lock payment authorization for ten minutes; repeating one request recovers the same rejection without consuming more attempts.

The bank uses PostgreSQL, one transaction per decision and a transaction-scoped per-bank advisory lock. First submissions after the signed 600-second deadline are rejected. Duplicate lookup precedes expiry/PIN decisions, so already-committed requests retain their original encrypted receipts. A changed body with the same sender/payment ID conflicts. New v1 PIN-less payments are rejected; previously stored v1 decisions remain recoverable after migration. Phone SQLite continues storing offline queues; PIN is omitted from local intent/history.


## Bank setup QR

Setup QRs encode public JSON: `{"type":"beyondnet-bank-setup","v":1,"bank_url":"https://bank.example","fingerprint":"<64 hex characters>"}`. These are distinct from recipient payment QRs and contain no account secrets. The app accepts only an HTTPS origin without credentials, paths, query or fragments and a valid full fingerprint. Camera and selected-image paths share the same parser and review step. Enrollment verifies actual bank key material against the imported fingerprint before sending signup/login credentials. The operator-authenticated `POST /api/admin/setup-qr` accepts `bank_url` and generates a PNG using the bank's own fingerprint, never a client-supplied fingerprint.

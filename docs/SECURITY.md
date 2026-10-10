# Security boundaries and remaining limits

This code demonstrates transport and simulated settlement. It is not audited payment infrastructure and is not connected to real UPI. It collects no real banking credentials, SMS OTPs, or UPI PINs.

## Implemented boundaries

- The user compares a full SHA-256 bank trust fingerprint from the laptop. Enrollment verifies public trust material before sending demo credentials.
- Passwords are scrypt-hashed in the bank database. Session and operator tokens are random and separate. Device registration is account-authenticated and requires proof of signing-key possession.
- Bank-issued certificates authenticate peer commands and bind device keys to an enrolled account and mesh. Optional allowlists constrain the demonstration route.
- Only the bank can decrypt payment bodies. Only an addressed device can decrypt its receipt. Ed25519 authenticates instructions and decisions; AES-GCM detects encrypted-payload tampering.
- A sender’s device lock authorizes payment signing; a separate six-digit demo PIN is encrypted to and verified by the bank. Relays cannot authorize a transfer. A forged receipt cannot produce a verified paid state.
- Settlement and receipt persistence are atomic, including durable rejected decisions and an idempotency key based on sender + payment ID.
- Queues, frame sizes, request bodies, peer sessions, inventories, and hop budgets are bounded. The gateway stores all returned receipts before marking upload complete.
- Bank keys persist across restart. Mobile keys and session data use platform secure storage. Android backups are disabled to reduce invalid key/database restoration.

## Live transport and funding

WebSocket sessions authenticate in their first TLS-protected frame (never URL query parameters), must name a device owned by that account, and recheck session expiry and device revocation. Submitted packets undergo the same signature, deduplication and atomic settlement checks as HTTPS. Device receipt inboxes are ownership-scoped. Live connections have message-size/rate limits, but deployment-wide connection/abuse controls remain future work.

Top-ups represent deliberately minted demo funds, not deposits. Request IDs are persisted before transmission and unique per account; retrying the same ID cannot add funds twice. Changed-amount reuse conflicts. Account balances and funding ledger entries commit in one transaction.

## What relays can see

Packet kind, size, lifetime, stable packet ID, mailbox capability, hop/path metadata, peer certificate identity, and transfer timing are observable. Payment amount and parties remain inside the bank-encrypted body, but peer identity can reveal an originating account. This is not an anonymity system. A relay may drop traffic or lie about having stored it; keeping other copies reduces but does not eliminate that risk.

Mailbox capabilities authorize retrieval of ciphertext for a single payment, and bearer authentication is also required. A participating relay already sees the request capability. It cannot decrypt the returned receipt without a device key. Protect capabilities anyway; do not put them in user-facing logs.

## Key and data storage

Mobile signing/encryption keys are software keys whose seeds are protected by OS secure storage. They are not claimed to be non-exportable Secure Enclave/Android Keystore signing keys. Once unlocked in the running app, key material exists in process memory. Device compromise can bypass UI authorization.

Phone SQLite contains own payment history and bank receipts plus opaque relay packets. It relies on the platform sandbox and device storage protection; SQLCipher is not implemented. Set a device screen lock. The laptop bank stores financial demo data in PostgreSQL and private keys in permission-restricted files. Use full-disk encryption and do not share `data/`.

## Demo-specific limits

- Legacy rehearsal accounts still have known demo passwords; new signup users choose their own passwords. Free funding is intentionally available to every authenticated account. A publicly exposed endpoint is therefore an intentionally shared demo environment, not private banking. Keep tunnels short-lived and supervised.
- Android opt-in relay uses a visible foreground service, persistent queue and timed CPU wake lease. Screen closure is supported; force-stop, reboot, permissions and manufacturer power restrictions can interrupt it. iOS background support and delivery guarantees are not included. See [background relay](BACKGROUND_RELAY.md).
- Peer revocation is immediately enforced by the bank for new submissions. Offline peers may continue trusting an old certificate until its 30-day expiry; a signed offline revocation distribution system is not implemented.
- Clock synchronization is required. Peer messages tolerate two minutes; new bank payment instructions tolerate at most 60 seconds in the future. Expiry uses signed timestamps at the bank.
- Wi-Fi mesh, real bank integrations, OTP/SIM identity verification, device recovery, key rotation, refunds, cancellation, chargebacks, signed invoices, private messaging, and high-availability deployment are not implemented.
- PostgreSQL transactions serialize bank writes with per-bank advisory locks; uniqueness constraints prevent duplicate decisions. The pause switch and rate counters are in memory. Do not deploy multiple workers and assume coordinated operational controls.
- The BLE command protocol has no transport confidentiality beyond encrypted application payloads and no durable cross-restart replay database. A captured authenticated command cannot create a new signed payment but may be replayed during its short clock window after restart. Adversarial availability protection needs further work.
- BLE radio throughput, advertising support, connection behavior, and battery usage vary by device. Hardware acceptance is mandatory.

## Before any real-money system

A licensed payment-provider integration and its security/compliance requirements would replace the demo bank and credentials. Independent cryptographic review, device-attested hardware keys where feasible, robust recovery/revocation, measured radio reliability, audited accounting, abuse controls, operational monitoring, and a defined dispute model are substantial additional work. This repository makes no production-readiness claim.


## PIN and expiry in Java 1.2.0

PIN setup/reset requires the account password over HTTPS. Bank PIN storage uses a fresh salt and scrypt hash; payment PIN input is never written to phone intent history or bank events. It exists briefly in process memory for signing/encryption/verification. Five unique wrong attempts lock authorization for 600 seconds; duplicate recovery does not add attempts. Never use a real UPI PIN in this demo.

New signed instructions have a maximum 600-second lifetime. Reachable payments settle immediately. Already-committed outcomes remain recoverable after expiry; unsubmitted expiry cannot debit funds. The existing X25519/HKDF/AES-256-GCM hybrid scheme and Ed25519 signatures are retained rather than replaced with RSA. PostgreSQL and the importer are implemented in Java. SQLite JDBC is included solely to read historical bank data once.

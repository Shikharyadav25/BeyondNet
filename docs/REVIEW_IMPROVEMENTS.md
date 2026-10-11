# Review of the earlier observations — release 1.3.3

The supplied review was compared with release 1.3.2. This update keeps the v2 encrypted-payment API and v1 BLE framing compatible. It does not change bank identity, balances, existing device keys, Android application ID or APK signing identity.

## Changes implemented

| Observation | Current action |
|---|---|
| Published demo passwords | Removed automatic account seeds. Startup recognizes only the old published demo passwords and replaces them with random passwords. IDs, devices and balances are preserved. Their old sessions are revoked. New credentials go to the private `data/rotated-demo-passwords.json`, excluded from distributions. Accounts already using another password are untouched. |
| Invalid old merchant suffix | New signup still requires `@beyondnet`. The existing `chai@beyond` identity is retained for history and receipt compatibility; renaming it would break signed authorizations and enrolled devices. New users should use the documented domain. |
| Live address in source | Distributed guides now contain placeholders. Bank URL and trust fingerprint are public enrollment information, not secrets. A fingerprint intentionally travels in the setup QR. Security depends on private keys and credentials, not hiding the URL. |
| Global tunnel rate bucket / variable paths / memory growth | Trust the rightmost forwarded client IP only from loopback, where the local tunnel connects. Normalize mailbox, recipient and receipt routes; add account-based login/signup limits and token-based PIN limits; expire buckets and cap the map at 10,000 entries. Never expose the loopback origin directly through an untrusted proxy. |
| Idle HTTP traffic | An established live connection avoids duplicate health/receipt calls. Health is checked every 30 seconds, recovery polling every 30 seconds, and full profile refresh every five minutes. Terminal payment mailboxes stop polling. The dashboard refreshes every 15 seconds only while visible. Free-provider quotas still apply. |
| Queued online latency | Prioritize bank work before BLE. A newly authorized payment requests immediate processing, including a follow-up pass if another pass is busy. Prioritize this phone's packets over relay backlog. Reuse a very recent balance refresh instead of repeating it immediately. No fixed latency guarantee is claimed. |
| Verified request rejected without receipt | Revoked sender devices and unavailable recipients now produce stored, signed, encrypted, idempotently recoverable rejections. Invalid ciphertext, forged signatures, unknown device keys and conflicting instructions still get transport errors: they cannot safely be treated as authenticated financial instructions. |
| New database connection for each call | HikariCP reuses a bounded four-connection pool. Add the ledger `(account,id)` index used for balance revisions. |
| One socket can block all others | Network/database work is dispatched per client using Java virtual threads, with coalescing and a 128-session cap. Concurrent session decorators serialize sends and bound buffering. The scheduler itself no longer performs clients' blocking database work. |
| One-second receipt polling | Successful transaction commits trigger queued socket updates. A 30-second sweep remains for cross-process changes and recovery. This is bounded demo infrastructure; an account-scoped distributed event broker is still future work. |
| Reconnect replays all receipts | Phones persist a device-specific receipt cursor and send it in the first socket frame. Old clients omitting it remain supported. |
| Bad receipt aborts live batch | Invalid or unverifiable receipts are isolated; valid siblings continue. Storage failures still interrupt delivery without advancing the cursor so they can be retried. |
| Profile error kills healthy connection | A non-authentication profile-refresh failure no longer closes an otherwise healthy socket. Authentication expiry still requires renewed login. |
| Relay fills payer storage | Foreign traffic is limited to 900 packets / 8 MiB, reserving 100 packets / 2 MiB for owned payments and verified owned receipts. Authenticated peer sources have a 100-packet cap. Incoming payment expiry cannot exceed ten minutes plus clock tolerance; receipts cannot exceed seven days plus tolerance. Quotas do not prevent radio jamming or attacks using many identities. |
| Low-entropy PIN hashes exposed in DB | New PIN hashes use a server-secret HMAC before scrypt. The idempotency commitment also uses a domain-separated HMAC, so a plain digest of the payment body cannot become another PIN-guessing oracle. The secret is in `data/pin-pepper.txt`, separate from PostgreSQL. Legacy PIN hashes upgrade after successful verification; legacy payment commitments upgrade when the original instruction is recovered. Users can reconfigure their PIN online to upgrade immediately. A DB leak before upgrading legacy rows remains a risk. Protecting the DB and the server together is still necessary. |
| Plain session tokens | Store SHA-256 token digests. Existing sessions migrate without changing the token held by normal clients. Add an idempotent `/api/logout` endpoint; the phone's full sign-out UX is future work. |
| Scrypt holds financial lock | Login/password confirmation and payment PIN hashing happen before acquiring the transaction lock. Inside the lock, recheck the stored credential hash and apply failure counters or a signed rejection if the PIN changed meanwhile. Financial balance/duplicate checks remain inside the lock. |
| Unbounded expired transport data | Bounded periodic deletion of expired sessions, mailboxes and device inbox receipts, and events older than 90 days. Preserve payment outcomes and the ledger indefinitely for idempotency and audit. Repeated encrypted receipts serve different delivery/recovery paths; deduplicating the payloads needs a separate schema migration. |
| Rehearsal shops in recipient directory | Exclude rehearsal shop accounts from the public merchant directory. Their records remain for audit; software rehearsal is explicitly labelled and does not prove physical Bluetooth performance. |
| Bad request parameters become 500 | Return 400 for invalid parameters and 415 for unsupported content type. Log unexpected exception classes without request bodies, PINs, tokens or database configuration. More detailed redacted monitoring remains future work. |
| Top-up changes entered amount silently | Refuse a different amount while an earlier top-up outcome is unresolved. Tell the user the earlier amount to retry. Preserve its request ID to prevent duplicate credit. |
| Recipient lookup during relay exchange | Wait for the active exchange, reserve the next radio operation for lookup, and give a bounded busy message if it does not finish. |
| Name-only payment confirmation | Show the bank-certified account ID alongside the display name before PIN entry. |
| Public operator dashboard | Allow `/`, `/static/*` and `/api/admin/*` only from direct loopback requests without tunnel forwarding headers. Phones still use the public payment API. |
| Java/Dart control-character canonicalization | Java now emits lowercase Unicode control escapes, matching Dart. Add a regression check. Existing ordinary signatures and bank identity are unchanged. |
| Schema and version drift | Local SQLite upgrades in place to version 3 with peer-source accounting. Java and phone release versions are now 1.3.3; Android build number is 10. |
| Secret file creation permissions | Create bank keys, operator token, PIN pepper and password-recovery files with restrictive permissions before writing content on POSIX systems. Backups now include the pepper and recovery file. |
| Runtime JAR accumulation | New launcher removes its own immutable runtime copy when it exits. Previously created copies are not automatically deleted because another process may still be using one. |
| Machine-specific guides / test database | Replace personal filesystem paths with portable examples. Test configuration accepts a local PostgreSQL database or a chosen config file; Neon is optional. Integration tests still need a real PostgreSQL service and use random test schemas. |

## Already present before this review

Android has a notification-backed foreground relay service, a retained engine, restart-safe ciphertext storage, custody acknowledgments, bounded fanout, path/trail loop avoidance and shorter-route repair. The statement that relay works only with the app open is outdated. Android can still stop it after force-stop, revoked permissions, Bluetooth being disabled or vendor battery restrictions; physical testing remains necessary.

The local database already upgraded from version 1 to 2 and used the correct Android query path for `PRAGMA busy_timeout`. Release 1.3.2 also added funds preflight, pending-payment reservations and clearer Bluetooth startup failures. These fixes were retained.

## Work deliberately deferred

- BLE MTU negotiation, numbered/replayable frames and identity privacy require a negotiated transport revision and mixed-version physical tests. The current 20-byte ATT-safe frames preserve installed-peer compatibility. Dropped exchanges produce no completed custody ACK; the original packet remains and retries. Frame loss can still reduce availability and throughput. Certificates still expose identity metadata to nearby peers, even though payment contents stay encrypted.
- The unauthenticated BLE session cap remains a denial-of-service limitation. Application-level signed peer commands do not eliminate attacks on the radio/session stage. A separate authenticated handshake and admission policy needs physical testing.
- A production signing certificate and renamed application ID require a planned distribution migration. Changing them now would prevent existing installations from updating or preserving their device keys and pending payments.
- Missing keystore keys cannot be safely recreated for encrypted pending outcomes. Recovery continues to preserve local data and requests restoration; automatic key replacement would make old receipts unreadable.
- Startup receipt verification is retained to recover interrupted writes. A verified-receipt checkpoint and native crypto acceleration should be benchmarked before changing recovery behaviour.
- Merchant-directory pagination, recipient search instead of full directories, reduced event-triggered local table reloads, a complete sign-out UI and normalized receipt storage remain useful follow-up work. The longer refresh interval reduces directory cost but does not solve large-directory growth.
- Rehearsal account creation is not yet a single isolated transaction/schema. Hidden rehearsal merchants no longer pollute the user directory, but a failed rehearsal can leave audit records. Do not delete financial records automatically to hide a failed run.

## Updating safely

Back up PostgreSQL and the private `data/` files, stop the previous bank, run `./start-bank.sh`, and install `installers/BeyondNet-Android-1.3.3.apk` over the existing phone app. Keep ngrok running and retain the same URL/fingerprint. If a legacy password was rotated, read the private recovery file locally and use **Renew login / update bank URL**. Do not share that file, the pepper, bank keys or operator key. Do not uninstall or clear phone storage while outcomes are unresolved.

These changes improve the demo. They are not a claim of production payment-system certification or proof of physical multi-hop reliability.

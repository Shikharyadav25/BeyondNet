# Campus transition — implementation and acceptance status

Prepared 18 October 2026. This branch is a **partial campus implementation**, not a complete
campus rollout. No hardware was available. The user requested empty content until approved
records are supplied. No institution network or external service has been deployed.

## Working software

- Existing demo payment flows retained; unchanged application ID, bank keys/history handling,
  financial packet, 600-second authorization and four-hop phone transport.
- Bank managed-gateway principals with expiring, hashed, rotatable/revocable credentials and
  separate submit/mailbox endpoints. They cannot log in as a customer or operate the bank.
- Campus Spring Boot service with separate PostgreSQL configuration, full-text public search,
  enrollment/revocation, bounded requests, signed query-bound responses and signed cache.
- Flutter Campus screen: explicit separate setup, verified HTTPS search, offline public cache,
  dated/source-labeled results, refresh, pagination and failure states. No fabricated records.
- Campus canonical contract and independent cross-language signature vector.
- Gateway **library components**: indexed framing, response cursors/ATT offsets, durable SQLite
  ciphertext queue, per-owner/class quotas, retry backoff, and fixed HTTPS bank upload/recovery.
  These components are tested, but they are not a running Linux Bluetooth gateway.

## Dependency-ordered remaining work

| Plan work package | Status / exit gate |
| --- | --- |
| 1. Payment baseline | Automated regression executed; physical three-phone runs pending hardware |
| 2. Gateway identity/contracts | Narrow bank HTTPS principal implemented; signed BLE gateway identity and negotiation still needed |
| 3. Linux GATT spike | Not implemented; must bind tested frame component to pinned BlueZ D-Bus adapter and compare with Android |
| 4. Gateway payment delivery | Queue/uplink libraries implemented; authenticated peer handling, supervised process and end-to-end radio flow still needed |
| 5–6. Campus search | Direct HTTPS and on-phone cache implemented; gateway-local SQLite FTS and campus BLE routing still needed |
| 7. Student messaging | Not implemented; requires reviewed recipient key protocol after gateway interoperability |
| 8. Multiple gateways/load | Software queue tests only; radio, failover, revocation propagation and load measurements pending |
| 9. Institution pilot | Pending approval, approved corpus, hardware, coverage and operational ownership |

The supplied plan explicitly allows an Android-only concept demonstration if Linux hardware is
unavailable and places messaging after gateway interoperability. This build follows that
limited demonstration path. It must not be presented as satisfying the remaining work packages.

## Operations and limitations

See [setup](SETUP.md), [acceptance](ACCEPTANCE.md), and [contract](../../contracts/README.md).
There is no chat UI, general proxy, web search provider, ERP integration or real payment service.
The campus server currently uses polling/HTTPS; it does not claim WSS inbox delivery.
Campus cache plaintext contains approved public information only. Queries are visible to the
campus endpoint. Token revocation blocks network access; already downloaded public cache can
remain usable until its signed expiry. Campus enrollment does not link financial accounts.
Gateway queues retain unresolved payments after authorization expiry for recovery. Their
bounded storage eventually refuses new custody; an authenticated retention/maintenance policy
must be completed before unattended deployment. No gateway daemon/systemd unit is installed.

# Campus protocol v1 — implemented public information subset

This is separate from the unchanged financial wire format in `docs/PROTOCOL.md`.
Never send campus JSON through a payment characteristic or the payment queue.

## Canonical signature

Ed25519 signs the UTF-8 bytes of `beyondnet/campus/v1\n` followed by canonical JSON of `body`.
The transport envelope has exactly `body` and `signature`; signature is standard padded Base64.
Canonical objects have lexicographically sorted string keys, arrays retain order, JSON has no
insignificant whitespace and strings use literal UTF-8 with JSON escaping. Values are strings,
booleans, null, signed integers, lists and objects; floating point is forbidden. Schema field
names are ASCII. Public keys are Base64 DER Ed25519 SubjectPublicKeyInfo (44 bytes).
The independent fixed vector in `vectors/campus-v1.json` is verified by Java and Dart tests.
The public test key is not an institution trust root.

All bodies include `v:1`, `kind`, `created_at` and `expires_at` in Unix seconds. Clients reject
future creation beyond 30 seconds and expiry at or before the local clock. Reliable device
clocks are required. Publisher trust is provisioned out of band; an advertised key is not trust.

* `public_cache`: up to 50 public records, bounded to 64 KiB on download, signed as one snapshot.
  Snapshot validity is 24 hours; individual record expiry is also checked. Download is HTTPS,
  not a BLE transfer. Refresh rejects rollback behind the previously stored creation time.
* `search_result`: includes original UUID `request_id`, normalized `query`, `page`, results,
  `has_more` and source. Valid for 60 seconds, maximum 4,096 encoded bytes including signature.
  Query is 1–256 UTF-8 bytes. Pages contain at most three records. Client checks request binding.
* `capabilities`: signed 60-second observation of this backend's available service. It does
  not prove bank reachability, gateway identity, receipt delivery or settlement.

Record fields: `id`, `title`, `body`, `source`, `updated_at`, `expires_at`.
Public-record publishing limits are 80 UTF-8 bytes for ID, 600 for body and 120 each for title
and source. Each canonical record is also capped at 1,000 bytes to reserve response overhead. Publish only approved public text. Empty content is the default.

Campus enrollment tokens authorize HTTPS search/cache access, last 30 days, are stored hashed
on the campus server and in secure storage on phones, and can be revoked/rotated locally.
They are not bank credentials or institution-verified messaging key certificates. Do not send
these tokens through an untrusted phone relay.

## Reserved transport identifiers and remaining protocol work

Campus service: `5cebe240-7de4-43eb-843b-96260d973a10`.
Campus indexed characteristic: `5cebe240-7de4-43eb-843b-96260d973a11`.
These identifiers are reserved, not advertised by this build. Payment UUIDs are unchanged.

The general signed/encrypted campus request envelope, gateway certificates, peer capability
negotiation, signed recipient directory, recipient encryption and delivery acknowledgements
are not implemented. Define and review these before enabling campus BLE or messaging. No
unknown campus packet is passed to the payment decoder.

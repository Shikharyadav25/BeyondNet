# Payment-first relay flow — BeyondNet 1.6.0 (build 28)

Use 1.6.0 on every participating phone and the updated bank. The Android package and local signing identity are preserved for in-place updates.

## Payment and custody

1. Enroll and set up the PIN online first. Cache a recipient or scan their valid bank-signed QR; arbitrary new-ID lookup requires a source of trusted recipient data.
2. Enter recipient, amount and PIN; finish device authentication. Bank connectivity and prior connection approval are no longer prerequisites to create the encrypted request.
3. The request and reservation are committed together. A phone with bank access submits directly. Otherwise Payment details shows delivery progress; enable Nearby delivery when prompted, including its Android permissions.
4. An eligible nearby phone receives an inbox item/notification. Accept & carry commits the request before acknowledging custody. Decline never submits it. Offline relays can accept without any known internet route.
5. An accepted relay automatically submits when it has bank access or searches for another carrier. Every new carrier explicitly accepts the request. No manual next-phone selection or second payer authorization is needed.
6. A known bank-capable peer ranks ahead of offline peers. Pending offers last up to 30 seconds; stale actions cannot approve a different offer generation. Lost acknowledgments are repaired from signed inventory.
7. One outward offer per packet is active at a time. Retain passive copies; wait at least 60 seconds after confirmed custody before fallback. At most two distinct possibly successful downstream carriers per holder and at most 32 recorded candidates per request. These local limits do not establish a network-wide copy limit.
8. A bank-signed delivery proof binds request ID and encrypted receipt hashes without revealing financial details. It stops redundant forwarding. Relays cannot read another person's receipt. Only the payer's verified private receipt changes the payment to paid/rejected.
9. Receipt exchange prefers the recorded return route and permits bounded alternate paths. Later bank inbox/mailbox recovery remains available. No reachable return path means receipt delivery waits.
10. The ten-minute payment authorization stops new forwarding at expiry. Unresolved reservations and original ciphertext remain for bank reconciliation; expiry is not a refund or a cancellation. Retries retain the original payment ID and instruction.

## Limits and controls

- Payment and receipt Bluetooth budgets are independent, each eight handoffs. A holder at the limit can still submit directly to the bank. Backend and app validators use matching limits.
- Routing capability 4 is required for new payment offers. Legacy payment `put`/pull paths cannot bypass per-request consent.
- Nearby uses the existing foreground service. Notification denial leaves requests accessible in the in-app inbox. Force-stop, Bluetooth/permission changes and battery restrictions can pause delivery.
- Payments and Campus use one Bluetooth owner at a time, with a clear message when switching is needed. This release prevents their services from replacing each other; simultaneous radio multiplexing is future work.
- Existing financial IDs, reservations, accepted payment consent, account identities and receipt history survive the SQLite version-7 migration. Connection approval is no longer a payment prerequisite.
- PIN correctness and balance settlement are decided at the bank; offline device authorization does not guarantee acceptance. Current clock/replay checks remain enforced; the bank controls financial expiry.

## Controlled phone test

A is the offline payer; B/C/D are offline relays; E has bank access. Enable Nearby on all and allow Android permissions. Enroll beforehand and obtain a recipient QR. Create one payment on A, accept its request on B, then C, D and E. E submits automatically; return phones into contact in reverse order if needed so the receipt reaches A while A remains offline.

Separate phones or use a test-only allowed-peer topology so A cannot directly contact E. A five-phone group together on a table can accidentally exercise one hop. Check Activity's bank-signed result, not just a transfer acknowledgment. Do not create a replacement payment while its outcome is unknown.

Automated tests use the production Dart RPC, framing, routing and SQLite paths. Live integration uses an isolated Spring Boot/PostgreSQL bank and controlled radio edges; actual radio range, locked-screen behavior and battery use still need physical-phone testing.

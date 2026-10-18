# Acceptance and hardware handoff

No physical result is claimed for this branch. Record operator, date, APK SHA-256 and signing
certificate, bank commit, phone models/Android versions, topology and gateway adapter/OS for
every run. Use test accounts. Keep actual result, expected result and evidence separately.

## Software checks

1. Run bank Java tests and full Flutter suite including the live Dart/Java payment test.
2. Run the campus Maven reactor with `CAMPUS_TEST_DB_URL` on disposable PostgreSQL.
3. Run Python payment compatibility tests after Flutter generates the Dart fixture.
4. Check signed cache alteration, expiry, wrong publisher and response/query mismatch rejection.
5. Publish an empty corpus: searches show no results. Publish only approved short records;
   refresh on the phone, disconnect internet and confirm source/date labels and expiry.
6. Rotate and revoke campus and bank gateway credentials; old credentials must fail. Gateway
   tokens must fail customer and operator authorization. Bank credentials must fail campus auth.
7. Reopen SQLite queue after custody; original bytes remain. Duplicate IDs with changed body,
   owner, type or expiry are rejected. Full quotas refuse custody; sender retains its copy.
8. Build APK and compare its application ID and signing certificate with the installed release.
   Never uninstall an enrolled phone merely to bypass an incompatible signature.

## Hardware gates before enabling the Linux gateway

- First reproduce ten consecutive A → B → online-phone gateway payment runs, including signed
  outcome recovery and exactly one bank debit/credit. Disclose imposed route restrictions.
- Implement pinned BlueZ D-Bus advertising/GATT integration. Exercise indexed frames at 20,
  negotiated MTU and 512 byte frames; duplicate writes, response cursors, ATT offsets, malformed
  frames, disconnects, timeouts and adapter restart. Existing frame tests are only software tests.
- Provision a signed managed-gateway peer identity; verify it on Android before automatic
  gateway policy. Preserve student-phone opt-in and explicit payment approvals.
- Complete durable queue → fixed bank uplink → signed outcome → phone recovery. Disconnect
  after bank commit, restart gateway, retry same packet and confirm the original decision.
- Add campus capability negotiation on its separate UUID; old payment peers must safely ignore
  it. Complete gateway-local signed cache validation, FTS and query-bound response verification.
- Test A → gateway, A → B → gateway, A → B → C → gateway with shortcuts prevented, then two
  gateways receiving the same payment. Test uplink outage, disk quota/full disk and power loss.
- Measure 1, 2, 5 and 10 active students: discovery success, p50/p95 transfer time, approval time
  separately, retries, completion rate, queue depth, process memory and Wi-Fi/BLE coexistence.

Only after these pass should recipient identity/key directory, encrypted inbox, idempotent
messaging, recipient delivery acknowledgements and multi-gateway synchronization be enabled.
Custody is never delivery, read status, payment settlement, fee clearance or an order dispense.
Institutional network approval, approved content, backups, monitoring and an accountable
operator remain pilot prerequisites. General browsing, ERP and real money are outside this build.

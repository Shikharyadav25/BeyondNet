# BeyondNet 1.4.4 — verified review fixes

Release date: 28 October 2026. Mobile **1.4.4+18**. Rebuild/restart the bank from this release; its compatible artifact name remains `bank-1.3.3.jar`.

The [review decisions](REVIEW_2026-10-28.md) distinguish verified bugs, accepted hardening, larger design changes and findings about removed code. This release fixes temporary database error classification, receipt routing validation and inbox progress, mailbox ownership, rejection-detail privacy, Bearer parsing, missing-account password work and rate-limit cleanup. The Python wire oracle now uses the same key ordering as the deployed Java/Dart code. It includes the prior Nearby switch recovery fixes.

## Verification

- Flutter suite: **125 passed**, including a real Dart-to-Java bank integration test using temporary identities and an isolated PostgreSQL instance.
- Java suite: **46 passed**, no failures, errors or skips. Added coverage includes injected database read failure and retry, malformed routes, durable mailbox ownership and backfill, invalid legacy receipt repair, rejection privacy and authorization parsing.
- Independent Python suite: **6 passed**, including HTTP/WebSocket/payment recovery, legacy import and the supplementary-key canonical vector.
- Flutter analysis: **no issues**.
- Native Android source is unchanged since the 20 passing Robolectric tests recorded for 1.4.2; that suite was not rerun for this patch. The Android release build validates packaging separately.
- APK build, version and existing signing identity are verified; see [artifact validation](releases/1.4.4-validation.json) and [checksums](../installers/SHA256SUMS.txt).

These checks cover software behavior, simulated transports and test failures. No Android phone was visible over USB. An actual APK upgrade and two/three-phone Bluetooth payment, radio range and manufacturer battery behavior remain physical acceptance tasks.

## Upgrade

1. Preserve bank data and private key files. Rebuild/restart the matching bank source. Startup adds a persistent mailbox ownership table and backfills saved receipt capabilities transactionally. Existing ledger entries, financial decisions and trust keys are retained. Do not run an older writer against the upgraded ledger.
2. Install `BeyondNet-Android-1.4.4.apk` **over the existing app** on participating phones. Do not uninstall or clear data. Application identity, signing certificate, phone SQLite schema and financial wire format are unchanged.
3. Sign in to the existing bank when needed. Existing valid hexadecimal capabilities of 32–100 characters remain compatible; new app capabilities remain 48 characters. External HTTP clients must send `Authorization: Bearer <token>`.
4. Test a small simulated payment with an offline sender and online gateway. Match the same signed bank reference in Activity and the ledger; repeat delivery to verify no second debit.
5. When testing a temporary bank outage, retry the original saved authorization. Do not create a replacement payment while the original outcome is unknown. A delivery acknowledgment alone is not settlement.

Malformed inbox entries no longer block later valid receipts. Local quota and database write failures keep the inbox cursor unchanged so the valid receipt can retry. Detailed PIN failures remain visible to the sender and operator; new/refreshed recipient receipts use generic rejection copy. Previously issued ciphertext is not retrospectively recalled.

This remains simulated INR. Routing hints, distributed denial of service, production key management, management-network isolation and real-money integration remain explicitly bounded by the [security notes](SECURITY.md).

# BeyondNet 1.4.5 — payment PIN setup reconnects correctly

Release date: 28 October 2026. Mobile **1.4.5+19**. Bank source is unchanged from 1.4.4; its compatible artifact name remains `bank-1.3.3.jar`.

## Fix

The PIN page previously read `bankReachable` when it built, but did not listen to connection changes. Opening it before the bank became reachable could leave “Save payment PIN” grey even after background checks recovered. The page now observes the engine, checks connectivity when opened, shows checking/connected/error state, and offers **Check bank connection** without leaving the form.

The Android internet-validation flag is now a hint rather than a reason to skip the HTTPS probe. A fingerprint-verified response from the configured bank establishes reachability. The native status request has a two-second deadline; an absent/error reply falls back to probing the bank. A failed bank connection cannot reuse the recent-live-session fast path to suppress recovery. A genuine offline phone or failed bank identity check still cannot configure its PIN.

The form validates a password, six PIN digits and matching confirmation before submitting. Save failures preserve form values, release the busy state, and show bank-provided errors such as an incorrect password or expired session. Successful setup clears the form and reports confirmation. The Device page version label is also corrected.

## Checks and limits

- Full Flutter suite: **131 passed**, including actual PIN setup against the isolated Java bank and simulated offline-payment/recovery tests.
- Six new regressions cover live connection changes, retry on the PIN page, save error/retry, incomplete form validation, a false Android connectivity hint and an unanswered native connectivity request.
- Static analysis: **no issues**. Signed APK build, application ID, version code and existing signing identity verified; see [artifact validation](releases/1.4.5-validation.json).
- Bank and native source were unchanged in this patch. Earlier baselines remain 46 Java and 6 Python tests for 1.4.4, plus 20 Android native tests from 27 October. These baseline suites were not rerun for this mobile-only fix.
- The development bank and public tunnel health checks returned HTTP 200. This does not establish connectivity from the reporting phone or prove it has the same configured bank URL.
- No ADB device was detected. Actual on-device installation, PIN setup and physical Bluetooth delivery remain acceptance steps.

## Install and retry

1. Install `BeyondNet-Android-1.4.5.apk` over the existing installation. Do not uninstall or clear data. The application ID, signing key, enrolled identity and SQLite schema are unchanged.
2. Connect this phone to the internet. PIN setup requires a direct online bank connection; a Bluetooth relay is not used for account/PIN setup.
3. Open **Payment PIN** and use **Check bank connection** if needed. When connected, enter the account password and matching six-digit PINs, then save. Confirm the bank success message.
4. If it still cannot connect, check the bank URL on Device and whether the bank/tunnel is running. An expired-session error requires sign-in; an incorrect-password error requires the account password, not the bank operator key.

This patch requires no additional bank rebuild when already using the 1.4.4 backend. Earlier bank installations should still be upgraded for the [1.4.4 review fixes](RELEASE_1.4.4.md). This release does not reset or set a real user's PIN during testing.

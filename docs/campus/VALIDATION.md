# Campus validation — 18 October 2026

Code tested: `3bbdf4d7d4cf5eb15a524a4a7e3c36457493bb91`.
Tests ran locally on an ARM Mac using isolated PostgreSQL 18.6 databases. No production
bank database, real funds, institution network or physical BLE hardware was used.

| Check | Result |
| --- | --- |
| Existing bank JUnit suite plus gateway credential regression | 35 passed |
| Campus contracts, PostgreSQL integration and gateway libraries | 11 passed; Java 21 |
| Full Flutter suite, including live Dart/Java bank and campus cache persistence | 104 passed |
| Flutter static analysis | No issues |
| Independent Python financial/wire compatibility | 5 passed |
| Running campus service | Started successfully; missing token rejected; empty cache/search returned; signatures independently verified |
| Android release build | Successful, version 1.4.0, build 14 |
| APK signature verification | Passed; certificate matches released 1.3.6 |
| Source packaging | New modules included; private data, keys, build output excluded |

The full Flutter regression initially exposed two test scrolling assumptions after the Campus
sign-in entry was added. The test helper now requires a hit-testable target; both QR review
flows and the complete suite then passed. An Intel-only local PostgreSQL client caused Python
cleanup failures; test cleanup now uses the pinned Python PostgreSQL driver.

## Android artifact

File: `dist/BeyondNet-Campus-1.4.0.apk` (local build artifact, not committed).

- Application ID: `com.offlinekaro.offline_karo`
- Version name/code: `1.4.0 / 14`
- APK SHA-256: `f632e5c5210ad9d651aaa0e1eab0a50abcd1fdb285e651abd92d5ae7a8b794ac`
- Signing certificate SHA-256: `87631ca5716266c5e82f64acff27185b6b1d84bd126128546545847427a07ff2`

The existing BLE plugin emits a warning about future Flutter compatibility with Kotlin Gradle
Plugin usage; it did not prevent this build. No phone installation or physical upgrade was performed.

## Unverified and unimplemented work

These results do not validate Linux/Android radio interoperability, campus coverage, three/four
physical phone chains, multiple gateways or production capacity. The Linux gateway module
contains library components, not a BlueZ daemon. Gateway peer certificates/negotiation, campus
BLE routing, gateway-local FTS and messaging remain unimplemented. See
[implementation status](IMPLEMENTATION.md) and [physical acceptance](ACCEPTANCE.md).

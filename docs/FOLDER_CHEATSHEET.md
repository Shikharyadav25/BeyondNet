# BeyondNet folder cheatsheet

A beginner’s map of the project. Read this first, then [the file cheatsheet](FILE_CHEATSHEET.md).

## What runs where?

| Part | Where it runs | What it does |
|---|---|---|
| Java bank | Laptop/server | Verifies payments, checks PIN and balance, writes outcomes and signs receipts. |
| PostgreSQL | Configured database; Neon in this setup | Stores accounts, balances, payment outcomes and ledger records. |
| Flutter + Android code | Participating phones | Provides screens, encrypts payments, stores packets and forwards them over Bluetooth LE. |
| Internet tunnel | Laptop | Gives the local bank a public HTTPS/WebSocket address. It does not process payments. |

The bank never joins Bluetooth. A phone with internet submits encrypted packets to it. Offline phones can forward packets through other participating phones.

## Folders you work in

| Folder | Easy explanation | When you open it |
|---|---|---|
| Project root | Main README, build entry points and desktop launchers. | Starting the bank, tunnel or installation tools. |
| `backend/` | The Java Spring Boot bank project. | Changing bank behavior or its build dependencies. |
| `backend/src/main/java/com/beyondnet/bank/` | Java classes for banking, cryptography, APIs and maintenance. | Changing account rules, payment validation, QR generation or live updates. |
| `backend/src/main/resources/` | Configuration and database structure packaged with the bank. | Understanding server settings or tables. |
| `backend/src/main/resources/static/` | Browser dashboard HTML, JavaScript and CSS. | Changing what the bank operator sees. |
| `backend/src/test/java/com/beyondnet/bank/` | Java checks for bank behavior and request validation. | Understanding existing checks or checking bank changes. |
| `mobile/` | Flutter phone project and its dependency configuration. | Building or changing the Android app. |
| `mobile/lib/` | Dart application code. | Understanding screens, payments, encryption, local storage and routing. |
| `mobile/android/` | Android-specific project and Gradle build configuration. | Changing platform settings or Android integration. |
| `mobile/android/app/` | The actual Android application module. | Changing Android app version, build settings or permissions. |
| `mobile/android/app/src/main/kotlin/com/offlinekaro/offline_karo/` | Native Android bridge and background relay service. | Understanding how relay operation continues without an open screen. The old package name is retained for compatibility. |
| `mobile/android/app/src/main/res/` | Icons, launch backgrounds and Android themes. | Changing app appearance during launch or notification icons. |
| `mobile/android/app/src/debug/` and `src/profile/` | Extra Android settings for development builds. | Understanding debug/profile builds. |
| `mobile/android/app/src/test/kotlin/` | Native Android checks. | Checking service, Bluetooth bridge and database startup behavior. |
| `mobile/android/gradle/wrapper/` | Pins the Gradle version used for Android builds. | Understanding consistent build tooling. |
| `mobile/test/` | Flutter/Dart checks. | Checking app logic, UI, routing, QR parsing and protocol compatibility. |
| `mobile/test/fixtures/` | Fixed sample messages used by tests. | Understanding known protocol examples. |
| `scripts/` | Helper tools for backup, packaging, installation and checking. | Automating routine developer tasks. Python here is tooling, not the bank server. |
| `tests/` | Cross-language and Java-bank integration checks driven by Python. | Checking Java/Dart agreement and bank integration. |
| `tests/support/` | Shared test helpers. | Understanding how independent protocol examples are generated. |
| `tests/fixtures/` | Sample legacy database data. | Understanding SQLite-to-PostgreSQL migration checks. |
| `docs/` | Setup, architecture, security and troubleshooting guides. | Learning or presenting the system. |
| `docs/diagrams/` | Diagram sources and displayable SVGs. | Editing or viewing architecture/build illustrations. |
| `docs/screenshots/` | Images used in documentation. | Adding visual explanations. |
| `installers/` | Built APKs, setup QR image and checksums. | Installing the phone app or sharing a demo package. |

## Local or generated folders

These may exist on a developer’s computer without appearing in Git.

| Folder | Purpose | What to remember |
|---|---|---|
| `data/` | Bank keys, operator key, PIN pepper, database configuration and local runtime files. | Protect and back up. With Neon, the main ledger lives in PostgreSQL, but these local secrets still matter. |
| `data/backups/` | Backups created by the backup helper. | Keep securely; they may contain private configuration and database data. |
| `backend/target/` | Maven output, including the runnable bank JAR. | Generated; rebuilding recreates it. The bank launcher may need to rebuild if it is absent. |
| `mobile/build/` | Generated Flutter/Android build output. | Generated; a new APK build recreates it. |
| `mobile/.dart_tool/` | Flutter/Dart tooling state. | Generated by dependency/build commands. |
| `mobile/android/.gradle/` and `.kotlin/` | Android build caches. | Generated; rebuilding can take longer after removal. |
| `dist/` | Source ZIP output. | Generated by the packaging script. |
| `.venv/` | Python environment for helper/integration checks. | It does not run the Java bank. |
| `.git/` | Repository history and branch information. | Removing it removes this checkout’s Git history/configuration. |

## Find the right part quickly

| Question | Start here |
|---|---|
| Why was a payment rejected? | `BankService.java`, dashboard Payments, and `docs/TROUBLESHOOTING.md` |
| How is encryption done? | Java `WireCrypto.java` and Dart `protocol.dart` |
| How are duplicate debits prevented? | `BankService.java`, `BankDatabase.java` and `schema.sql` |
| How does an offline chain forward packets? | `engine.dart`, `relay_routing.dart`, `ble_transport.dart` and `store.dart` |
| How does relay work in the background? | `background_relay.dart`, `RelayEngineHost.kt` and `RelayService.kt` |
| Where are screens? | `mobile/lib/main.dart`, PIN and bank-setup scan files |
| Where is the bank dashboard? | `backend/src/main/resources/static/` |
| How do I run it? | `docs/RUN_GUIDE.md` |

## Account deletion: current status

There is currently no admin delete-account endpoint or user delete-profile screen. Device revocation exists, but it does not close an account. Logout only removes a session.

A future account-closure feature should authenticate the request, handle remaining balance, mark the account closed, revoke its devices and sessions, block new spending/recipient use, and stop local relay participation for the closing user. The bank must also reject still-unprocessed packets from closed accounts; deleting the phone’s local profile alone would not do that.

Committed payment outcomes and ledger entries should remain consistent. Existing duplicate payment requests should recover their recorded outcome rather than cause another debit. Closure must be coordinated with payment transactions so a payment and closure cannot race. Decide explicitly how historical profile details are retained or anonymized rather than deleting financial history blindly.

This is a proposed feature, not implemented behavior.

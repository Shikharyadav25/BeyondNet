# BeyondNet file cheatsheet

Plain-language use cases for every tracked file in this checkout, plus these two cheatsheets. Paths are relative to the project root. Generated and private files are explained separately below. Read [the folder cheatsheet](FOLDER_CHEATSHEET.md) for the big picture.

## Read these first

1. `README.md` — understand the product.
2. `docs/RUN_GUIDE.md` — start and use it.
3. Java: `BankApplication.java` → `BankController.java` → `BankService.java` → `BankDatabase.java`.
4. Phone: `main.dart` → `engine.dart` → `protocol.dart` / `store.dart` → `ble_transport.dart` / `relay_routing.dart`.
5. Background: `background_relay.dart` → `RelayEngineHost.kt` → `RelayService.kt`.

The Java bank uses PostgreSQL. The phone uses SQLite for local packet/state storage. Python files are helpers/tests, not a second bank backend. Kotlin provides Android-specific support alongside Flutter/Dart.

## Root launchers and configuration

| File | What it is used for |
|---|---|
| `.gitignore` | Keeps runtime secrets, caches and generated output out of Git. |
| `Install-Android.command` | Mac launcher for the USB Android installation helper. |
| `README.md` | Project overview: features, architecture, setup links and limitations. |
| `Share-Android.command` | Mac launcher for the local APK sharing helper. |
| `Start-Bank.command` | Mac double-click launcher for the Java bank startup script. |
| `Start-Ngrok.command` | Starts the internet tunnel so phones can reach the local bank through HTTPS/WSS. |
| `pytest.ini` | Configures Python-based checks. |
| `requirements-test.txt` | Lists Python libraries used by test tooling; not bank-server dependencies. |
| `start-bank.ps1` | Windows PowerShell entry point for starting the Java bank. |
| `start-bank.sh` | Starts the Java bank using the configured database and build/runtime setup. |

## Java bank

| File | What it is used for |
|---|---|
| `backend/pom.xml` | Maven recipe: Java version, Spring Boot, PostgreSQL, crypto, QR and test dependencies. |
| `backend/src/main/java/com/beyondnet/bank/BankApplication.java` | Java entry point. Starts Spring Boot, or performs migration-only initialization. |
| `backend/src/main/java/com/beyondnet/bank/BankController.java` | Maps HTTP URLs to bank operations and returns controlled API errors. |
| `backend/src/main/java/com/beyondnet/bank/BankDatabase.java` | Manages PostgreSQL connections, schema setup, transactions, write serialization and commit notifications. |
| `backend/src/main/java/com/beyondnet/bank/BankException.java` | Carries an intended HTTP status and understandable error message. |
| `backend/src/main/java/com/beyondnet/bank/BankMaintenance.java` | Removes expired sessions/delivery records and old events in small batches; preserves payment outcomes and ledger entries. |
| `backend/src/main/java/com/beyondnet/bank/BankService.java` | Main bank rules: signup, login, PINs, devices, demo funding, payment verification, atomic settlement and signed receipts. |
| `backend/src/main/java/com/beyondnet/bank/BankSetupQr.java` | Validates the public HTTPS origin and generates a setup QR containing bank URL and fingerprint. |
| `backend/src/main/java/com/beyondnet/bank/LegacySqliteImport.java` | Imports an existing legacy SQLite bank into PostgreSQL with consistency checks. Not the active bank database. |
| `backend/src/main/java/com/beyondnet/bank/LiveSocket.java` | Authenticates live WebSocket connections and sends account updates and encrypted receipts after commits. |
| `backend/src/main/java/com/beyondnet/bank/RehearsalService.java` | Creates simulation accounts and exercises real crypto/settlement/duplicate handling. Adds records without using physical Bluetooth. |
| `backend/src/main/java/com/beyondnet/bank/RequestLimits.java` | Limits request sizes and attempts, and restricts the dashboard/admin routes to localhost. |
| `backend/src/main/java/com/beyondnet/bank/StaticAssets.java` | Serves dashboard JavaScript and CSS from packaged resources. |
| `backend/src/main/java/com/beyondnet/bank/WireCrypto.java` | Java wire-format and crypto helpers: canonical JSON, Ed25519 signatures, X25519/HKDF/AES-GCM boxes, hashes and packet validation. |

## Bank resources and dashboard

| File | What it is used for |
|---|---|
| `backend/src/main/resources/application.properties` | Spring server address/port, application name, logging and JSON parsing settings. |
| `backend/src/main/resources/postgres.neon.properties.example` | Example secure Neon PostgreSQL connection settings. |
| `backend/src/main/resources/postgres.properties.example` | Example PostgreSQL connection configuration; copy and fill locally rather than putting real secrets into the example. |
| `backend/src/main/resources/schema.sql` | Creates account, device, payment, ledger, session, PIN, mailbox and related tables/indexes. |
| `backend/src/main/resources/static/app.js` | Dashboard actions: authorized API calls, rendering, refresh, pause/resume, rehearsal and QR downloads. |
| `backend/src/main/resources/static/index.html` | Dashboard structure: overview, payments, ledger, setup QR and operator login. |
| `backend/src/main/resources/static/style.css` | Dashboard colors, spacing, tables, dialog and responsive layouts. |

## Java checks

| File | What it is used for |
|---|---|
| `backend/src/test/java/com/beyondnet/bank/BankServiceTest.java` | Checks bank behavior including financial and authorization scenarios. |
| `backend/src/test/java/com/beyondnet/bank/BankSetupQrTest.java` | Checks setup QR payload generation and URL validation. |
| `backend/src/test/java/com/beyondnet/bank/RequestLimitsTest.java` | Checks request limiting and local dashboard access rules. |
| `backend/src/test/java/com/beyondnet/bank/WireCanonicalTest.java` | Checks exact canonical JSON/protocol behavior used for signatures and hashes. |

## Flutter configuration

| File | What it is used for |
|---|---|
| `mobile/.gitignore` | Keeps generated Flutter output out of Git. |
| `mobile/.metadata` | Flutter project metadata used by development tooling. |
| `mobile/README.md` | Phone-app setup and development notes. |
| `mobile/analysis_options.yaml` | Dart static-analysis/lint rules. |
| `mobile/dart_test.yaml` | Declares the integration-test tag used to classify tests. |
| `mobile/pubspec.lock` | Records exact resolved dependency versions for repeatable dependency installation. |
| `mobile/pubspec.yaml` | Flutter app version, dependencies and project configuration. |

## Flutter application

| File | What it is used for |
|---|---|
| `mobile/lib/android_ble_session.dart` | Reopens the Android BLE GATT server through the pinned plugin bridge; handles Bluetooth session startup. |
| `mobile/lib/background_relay.dart` | Dart bridge to start/stop native relay service, read readiness and open battery settings. |
| `mobile/lib/bank_setup_code.dart` | Parses and validates bank-setup QR configuration before use. |
| `mobile/lib/bank_setup_scan.dart` | Camera QR screen plus gallery-image decoding and image-picker recovery. |
| `mobile/lib/ble_transport.dart` | Bluetooth LE discovery, advertising, connections and framed peer-message transport. |
| `mobile/lib/engine.dart` | Coordinates login, enrollment, funding, online submissions, offline forwarding, retries, balances and receipts. |
| `mobile/lib/main.dart` | Flutter entry point and primary screens: signup/login, home, nearby, device settings, pay, receive and activity. |
| `mobile/lib/nearby_permissions.dart` | Checks and requests the Android permissions needed for nearby Bluetooth operation. |
| `mobile/lib/payment_pin.dart` | PIN entry/configuration UI used to authorize demo payments. |
| `mobile/lib/protocol.dart` | Dart equivalent of Java wire crypto: canonical JSON, signing, encryption, packet IDs and validation. |
| `mobile/lib/relay_routing.dart` | Forwarding decisions: loop avoidance, hop limits, return-path priority and fair ordering. |
| `mobile/lib/store.dart` | Phone-local SQLite persistence for identity/configuration, packets, receipts, relay acknowledgments and replay protection. This is separate from bank PostgreSQL. |

## Android integration and resources

| File | What it is used for |
|---|---|
| `mobile/android/.gitignore` | Excludes Android machine-specific settings and generated files. |
| `mobile/android/app/build.gradle.kts` | Android application ID, SDK targets, version/build integration and build settings. |
| `mobile/android/app/src/debug/AndroidManifest.xml` | Extra manifest settings for Flutter debug builds. |
| `mobile/android/app/src/main/AndroidManifest.xml` | Declares Android permissions, app activity and foreground relay service. |
| `mobile/android/app/src/main/kotlin/com/offlinekaro/offline_karo/MainActivity.kt` | Android screen host that attaches to the shared Flutter engine and coordinates activity visibility. |
| `mobile/android/app/src/main/kotlin/com/offlinekaro/offline_karo/RelayEngineHost.kt` | Owns one application-scoped Flutter engine and native method channels; checks radio/network readiness and remembers relay opt-in. |
| `mobile/android/app/src/main/kotlin/com/offlinekaro/offline_karo/RelayService.kt` | Visible Android foreground service that retains relay operation when the app screen closes; provides service lifecycle and stop control. |
| `mobile/android/app/src/main/res/drawable-v21/launch_background.xml` | Android launch-screen background; drawable-v21 is the Android 5+ resource variant. |
| `mobile/android/app/src/main/res/drawable/ic_relay.xml` | Vector icon for the visible relay-service notification. |
| `mobile/android/app/src/main/res/drawable/launch_background.xml` | Android launch-screen background; drawable-v21 is the Android 5+ resource variant. |
| `mobile/android/app/src/main/res/mipmap-hdpi/ic_launcher.png` | Android launcher icon at this screen-density size; Android selects the appropriate variant. |
| `mobile/android/app/src/main/res/mipmap-mdpi/ic_launcher.png` | Android launcher icon at this screen-density size; Android selects the appropriate variant. |
| `mobile/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png` | Android launcher icon at this screen-density size; Android selects the appropriate variant. |
| `mobile/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` | Android launcher icon at this screen-density size; Android selects the appropriate variant. |
| `mobile/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` | Android launcher icon at this screen-density size; Android selects the appropriate variant. |
| `mobile/android/app/src/main/res/values-night/styles.xml` | Android launch/normal theme definitions for dark-mode devices. |
| `mobile/android/app/src/main/res/values/styles.xml` | Android launch/normal theme definitions. |
| `mobile/android/app/src/profile/AndroidManifest.xml` | Extra manifest settings for Flutter profile builds. |
| `mobile/android/app/src/test/kotlin/com/offlinekaro/offline_karo/BluetoothSessionApiTest.kt` | Checks the Android/plugin Bluetooth session bridge contract. |
| `mobile/android/app/src/test/kotlin/com/offlinekaro/offline_karo/RelayServiceTest.kt` | Checks native background-relay service behavior. |
| `mobile/android/app/src/test/kotlin/com/tekartik/sqflite/DatabaseStartupTest.kt` | Checks SQLite startup handling, including the Android PRAGMA regression. |
| `mobile/android/build.gradle.kts` | Shared Android Gradle configuration. |
| `mobile/android/gradle.properties` | Android Gradle build properties and JVM settings. |
| `mobile/android/gradle/wrapper/gradle-wrapper.properties` | Pins the Gradle distribution used by the Android build wrapper. |
| `mobile/android/settings.gradle.kts` | Registers Flutter/Gradle plugins and the Android app module. |

## Flutter checks

| File | What it is used for |
|---|---|
| `mobile/test/background_relay_test.dart` | Checks the Dart/native background service bridge. |
| `mobile/test/bank_setup_test.dart` | Checks setup QR parsing and validation. |
| `mobile/test/ble_startup_test.dart` | Checks BLE server startup/session handling. |
| `mobile/test/engine_test.dart` | Checks payment-engine behavior with controlled dependencies. |
| `mobile/test/fixtures/python-wire.json` | Fixed cross-language wire examples for protocol checks, not live account data. |
| `mobile/test/live_bank_test.dart` | Integration checks involving the running Java bank and Dart client. |
| `mobile/test/nearby_permissions_test.dart` | Checks Android-version-specific permission requirements. |
| `mobile/test/protocol_test.dart` | Checks Dart signing, encryption and packet protocol behavior. |
| `mobile/test/relay_reliability_test.dart` | Checks forwarding/recovery rules, loops and chain reliability logic. |
| `mobile/test/rpc_replay_test.dart` | Checks persistent duplicate/replay rejection for signed peer commands across engine restarts and clock/capacity cases. |
| `mobile/test/widget_test.dart` | Checks Flutter screen/widget behavior. |

## Scripts

| File | What it is used for |
|---|---|
| `scripts/backup-bank.sh` | Creates a bank backup including PostgreSQL export and required local bank state. |
| `scripts/check.sh` | Runs the project verification workflow. |
| `scripts/database-config.sh` | Shared database-configuration reader for shell helpers; does not evaluate configuration as shell code. |
| `scripts/install_android.py` | Finds connected Android devices and installs the APK through Android tooling. |
| `scripts/package_source.py` | Builds a source ZIP while excluding secrets, caches and generated/private files. |
| `scripts/share_android.py` | Serves an APK download page on the local network for phone installation. |
| `scripts/start-postgres.sh` | Starts the optional dedicated local PostgreSQL setup. Remote Neon is configured separately. |
| `scripts/stop-postgres.sh` | Stops the retired/local PostgreSQL cluster; does not stop Neon. |
| `scripts/test_java_bank.py` | Starts an isolated Java bank for integration checks. |
| `scripts/test_postgres.py` | Supplies test database configuration and isolated schema cleanup. |

## Integration checks

| File | What it is used for |
|---|---|
| `tests/__init__.py` | Marks the integration-test directory as a Python package. |
| `tests/fixtures/legacy-migration.json` | Sample old-bank data used to verify migration consistency. |
| `tests/support/__init__.py` | Marks shared test helpers as a Python package. |
| `tests/support/wire_oracle.py` | Independent Python wire-format/cryptography helper for compatibility checks; not a production server. |
| `tests/test_dart_interop.py` | Checks that Dart and Java agree on protocol messages and bank integration. |
| `tests/test_java_bank.py` | Python-driven integration checks of the Java bank, including persistence/migration behavior. |

## Documentation and diagrams

| File | What it is used for |
|---|---|
| `docs/ARCHITECTURE.md` | How the bank, phones, storage, enrollment and payment flows fit together. |
| `docs/BACKGROUND_RELAY.md` | Background relay implementation, routing rules and physical-phone acceptance procedure. |
| `docs/BUILD_FLOW.md` | Developer build order from Java foundation through Flutter and APK packaging. |
| `docs/DEVELOPMENT.md` | Developer commands and rules for changing/checking the project. |
| `docs/FILE_CHEATSHEET.md` | This guide: beginner explanation of every tracked project file. |
| `docs/FIRST_PAYMENT.md` | Step-by-step first online and offline demo payment. |
| `docs/FOLDER_CHEATSHEET.md` | Beginner explanation of each project folder and where to look for a task. |
| `docs/NEON_SETUP.md` | Remote PostgreSQL setup, deployment configuration and recovery guidance. |
| `docs/NGROK.md` | Public bank tunnel setup, restart and availability notes. |
| `docs/PHONE_INSTALLATION.md` | Installing or building the Android APK. |
| `docs/PROTOCOL.md` | Exact packet formats, crypto envelopes, HTTP/BLE commands and retention rules. |
| `docs/REVIEW_IMPROVEMENTS.md` | Earlier review findings, changes made and work deferred. |
| `docs/RUN_GUIDE.md` | Commands and practical instructions for starting, stopping and using the demo. |
| `docs/SECURITY.md` | Implemented security boundaries and remaining limitations. |
| `docs/SECURITY_ROADMAP.md` | Security suggestions, immediate changes and future upgrade plans. |
| `docs/SPRING_BOOT_SETUP.md` | Java-bank/PostgreSQL setup and migration/restart guidance. |
| `docs/TROUBLESHOOTING.md` | Common payment, permissions, database startup and installation problems. |
| `docs/VALIDATION.md` | Recorded verification evidence and its practical limits. |
| `docs/diagrams/build-flow.dot` | Graphviz DOT source for the developer build flow diagram. |
| `docs/diagrams/build-flow.mmd` | Mermaid source for the developer build flow diagram. |
| `docs/diagrams/build-flow.svg` | Viewable SVG illustration of the developer build flow. |
| `docs/diagrams/payment-flow.dot` | Graphviz DOT source for the payment flow diagram. |
| `docs/diagrams/payment-flow.svg` | Viewable SVG illustration of the payment flow. |
| `docs/screenshots/bank-setup-qr.png` | Setup QR screenshot used in documentation. |

## Installers

| File | What it is used for |
|---|---|
| `installers/BeyondNet-Android-1.2.1.apk` | Archived older Android release; keep separate from the current release. |
| `installers/BeyondNet-Android-1.3.4.apk` | Current checked-in Android release package. |
| `installers/BeyondNet-Android.apk` | Convenience symlink pointing to the selected Android release. |
| `installers/BeyondNet-bank-setup.png` | Exported setup QR image. Its URL/fingerprint belong to the bank configuration at generation time. |
| `installers/SHA256SUMS.txt` | Checksums for verifying installer artifact integrity. |

## Important local/generated files (not source-code features)

These can exist locally and are deliberately not all tracked in Git. Names and output versions can change with a build.

| File | Use case |
|---|---|
| `data/postgres.properties` | Actual database connection settings; contains private credentials. |
| `data/bank-keys.json` | Persistent bank signing/encryption identity. Replacing it changes bank trust. |
| `data/admin-token.txt` | Operator key for the localhost dashboard. |
| `data/pin-pepper.txt` | Bank secret used to protect PIN hashes and payment commitment hashes. |
| `data/rotated-demo-passwords.json` | Recovery information for rotated legacy demo passwords, if migration created it. |
| `data/public-url.txt` | Saved public HTTPS origin for setup QR defaults. |
| `data/.bank-java.lock` | Local lease used to avoid two bank processes sharing the same bank directory. |
| `data/bank.sqlite3` | Legacy bank database, if present, used only as migration input. |
| `backend/target/bank-<version>.jar` | Built executable Java bank. |
| `dist/BeyondNet-source.zip` | Generated source-code distribution. |
| `mobile/android/local.properties` | This computer’s Android/Flutter SDK locations. |
| `mobile/android/gradlew` / `gradlew.bat` and wrapper JAR | Gradle launcher tooling, when available/generated locally. |
| `mobile/.flutter-plugins-dependencies` | Generated Flutter plugin-registration metadata. |
| `mobile/build/app/outputs/flutter-apk/app-release.apk` | APK generated by a release build before copying into installers. |

Do not publish private bank files in screenshots, Git or a source ZIP. Removing caches is different from removing bank identity/configuration.

## Common changes: which files matter?

| Desired change | Files to inspect |
|---|---|
| Account rules or payment rejection | `BankService.java`; expose new operations in `BankController.java` |
| Database structure | `schema.sql`, `BankDatabase.java`, and callers using those tables |
| Crypto or signed packet format | `WireCrypto.java`, `protocol.dart`, `PROTOCOL.md`, interoperability checks |
| Offline forwarding/retries | `engine.dart`, `relay_routing.dart`, `store.dart`, `ble_transport.dart` |
| Background behavior | `background_relay.dart`, `RelayEngineHost.kt`, `RelayService.kt`, Android manifest |
| Phone appearance | `main.dart`, `payment_pin.dart`, `bank_setup_scan.dart` |
| Bank dashboard appearance | `index.html`, `app.js`, `style.css` |
| Bank setup QR | `BankSetupQr.java`, `bank_setup_code.dart`, `bank_setup_scan.dart` |
| APK version/dependencies | `pubspec.yaml`, `pubspec.lock`, Android build configuration |
| Proposed account closure | Bank schema/service/controller, dashboard controls, Flutter engine/settings and authorization checks; not implemented yet |

## What “delete” means today

`BankService.revoke()` revokes a device. `logout()` invalidates a session. Maintenance removes expired temporary records. None of these deletes a user profile or account. Existing payment and ledger records remain. See the folder guide for the proposed account-closure design.

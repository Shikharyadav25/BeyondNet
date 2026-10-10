> **Current laptop configuration:** PostgreSQL is now on Neon. The launcher uses the private remote configuration and skips local database startup. See [Neon setup and restart guide](NEON_SETUP.md). Local-cluster instructions below apply only to a fresh local development setup.

# Developer commands and rules

Read [BUILD_FLOW.md](BUILD_FLOW.md) for the complete implementation order, file responsibilities and flowcharts. The bank is Java 21+ / Spring Boot 4.1.1 / PostgreSQL; the Android client is Flutter 3.44+ / Dart 3.12+.

From the project root:

```sh
./start-bank.sh
```

Manual backend build: `mvn -f backend/pom.xml package`. With PostgreSQL configured, run `java -jar backend/target/bank-1.2.0.jar` from the project root. The versioned JAR name is independent of phone version 1.3.0. Dashboard: `http://localhost:8080`. Custom Java port: `--server.port=8081`.

Build Android:

```sh
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

Minimum API 29; compile SDK 37; target SDK 36. Preserve application ID and signing identity when upgrading an enrolled phone. This demo uses a development signing certificate.

## Full verification

Python is needed only for test orchestration and an independent wire oracle:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-test.txt
./scripts/check.sh
```

Set `FLUTTER_BIN` if Flutter is not on PATH. Tests use temporary bank identities and random PostgreSQL `test_*` schemas. They do not spend from real demo accounts. `tests/fixtures/legacy-migration.json` contains synthetic public test credentials and a frozen legacy SQLite dump; it never starts the removed Python backend.

## Changes that require particular care

- Keep Java and Dart canonicalization, key/nonce/tag encoding, crypto domain and signature fields identical. Repeat fixture and live Dart-to-Java tests after crypto changes.
- Use a single timestamp for creation and the 600-second authorization deadline. Save ciphertext and redacted intent atomically; never save/log plaintext PINs.
- Put all bank financial read/check/write work inside `BankDatabase.tx`. Its database advisory lock and uniqueness constraints prevent duplicate debit and overspending across gateways/instances.
- Verify signed receipts against the original intent. A transport acknowledgment, timeout or local expiry is not settlement or refund.
- Keep private `data/` out of Git and distributions. Preserve bank keys/operator key alongside PostgreSQL backups.
- Keep the legacy wire domain, BLE UUIDs and application ID: these are compatibility identifiers, not stale product branding.

Package clean source with `python3 scripts/package_source.py`; output is `dist/BeyondNet-source.zip`. The package excludes identities, databases, dependency caches, native signing files and compiled APKs. Installation and restart instructions are in [SPRING_BOOT_SETUP.md](SPRING_BOOT_SETUP.md).

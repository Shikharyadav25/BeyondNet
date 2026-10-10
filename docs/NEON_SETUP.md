# BeyondNet bank on Neon PostgreSQL

## Current deployment

The bank's **database is hosted on Neon**, not on this Mac's PostgreSQL cluster. The project was created on the Free plan in organization `org-holy-cake-25129267`.

- Project: BeyondNet (`delicate-shadow-39725279`)
- Branch: production (`br-dawn-frog-b31m64e6`)
- Region: AWS Singapore
- PostgreSQL: 18
- Database: `neondb`
- Private configuration: `data/postgres.properties`
- Migration evidence: `data/neon-migration-verification.json`

All values in the existing bank's **11 tables** were compared before switching. Bank keys and the operator key remain on this Mac and preserve the fingerprint, existing accounts/devices and receipts. Do not delete those small identity files. The phone's offline SQLite is separate and remains necessary.

The JDBC connection uses `sslmode=verify-full` with the default Java trust store and a connection timeout. Backups use libpq's system CA trust. Credentials are stored only in permission-restricted, ignored configuration; no database password is shipped inside the APK or source ZIP. See [PostgreSQL JDBC SSL documentation](https://jdbc.postgresql.org/documentation/ssl/) for hostname/certificate validation.

## Start on this configured Mac

Terminal 1:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
./start-bank.sh
```

The launcher detects a remote PostgreSQL URL and **does not initialize or start a local database**. Keep the bank terminal open.

Terminal 2, if ngrok is not already running:

```sh
cd /Users/shikharyadav/Desktop/Projects/BeyondNet
./Start-Ngrok.command
```

Dashboard: `http://localhost:8080`. Phones continue using the same public HTTPS bank URL and fingerprint. This database migration requires **no APK update or phone re-enrollment**.

Read the existing operator key:

```sh
cat /Users/shikharyadav/Desktop/Projects/BeyondNet/data/admin-token.txt
```

## What still runs locally

Neon hosts PostgreSQL only. The Java bank, its cryptographic identity and ngrok still run on this laptop. The laptop must remain awake and online to process payments. Moving the bank service to a separate host is a different deployment step.

Neon's Free plan may suspend idle compute; waking the database can make the first request slower. Retained ciphertext/idempotent recovery handles interruption; pending does not mean paid. Do not change the payment ID or submit a replacement solely because the first response was delayed.

## Backups and recovery

```sh
./scripts/backup-bank.sh
```

The backup command now dumps **the configured Neon database**, not hardcoded localhost. It also copies the matching small identity/config files. A manual backup creates a local private dump; if local space is limited, move it to secure external storage and remove it locally afterward. Do not commit or share credentials/backups.

A verified cloud snapshot is retained as `migration-backup-2026-10-10` (`br-muddy-grass-b3t2ni0p`), with no automatic expiration. It captures the migration and subsequent rehearsal; it is a snapshot, not an automatically updated backup. For future cloud-side recovery, use this Neon project's branch/history features. Keep the signing/encryption key files separately: a database branch cannot recreate the bank's private identity. Restoring an earlier ledger is a deliberate recovery operation, not a normal restart.

## Fresh source checkout / developer tests

A source ZIP excludes the live Neon credentials and private keys. Configure your own Neon test database in `data/postgres.properties` using [the example](../backend/src/main/resources/postgres.neon.properties.example); use the matching bank identity only when deliberately moving this existing bank. A fresh identity means a different trust fingerprint.

`./scripts/check.sh` uses random `test_*` schemas and temporary identities. Test cleanup is TLS-verified for a remote database. Tests do not modify public bank accounts, but they do use database compute/space temporarily. Never test in the real public ledger.

Local database helpers remain available for other developers. On this configured checkout `scripts/start-postgres.sh` detects Neon and exits without creating local storage. Do not replace the active remote configuration with a localhost URL unless deliberately setting up a separate local bank.

## Storage removal

The retired local PostgreSQL cluster, old bank SQLite snapshot and local database dump copies have been deleted after Neon/Java validation and verified cloud snapshot creation. Including unused runtime JAR copies, **196.4 MiB** was freed. Bank identity/configuration and the current runtime JAR remain required. Generated SDK/dependency/build caches and old source archives are not bank database storage.

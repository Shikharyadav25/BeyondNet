# Campus software setup

Requires Java 21+, Maven, Flutter 3.44+ and PostgreSQL 17+. Keep the original bank setup and
private keys intact. These commands do not configure institution Wi-Fi or publish a server.

## Build and verify

```sh
mvn install
mvn -f backend/pom.xml package
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

`mvn install` builds only the campus reactor (contracts, campus-backend, gateway); the existing
bank stays independently buildable. Campus PostgreSQL integration tests require
`CAMPUS_TEST_DB_URL` and `CAMPUS_TEST_DB_USER`; use a disposable database whose role can create
and drop `test_*` schemas. Without that variable, those two tests are explicitly skipped.
The original bank tests use the existing `BEYONDNET_DB_CONFIG` convention and isolated schemas.
Independent Python tests require Python 3.10+ and `requirements-test.txt`.

## Dedicated campus database and identity

Create a separate PostgreSQL database and restricted login role for campus data. Do not give
that role access to the bank database. Set the following in a private environment file (0600):

```sh
export CAMPUS_DB_URL='jdbc:postgresql://127.0.0.1:5432/beyondnet_campus'
export CAMPUS_DB_USER='beyondnet_campus'
export CAMPUS_DB_PASSWORD='YOUR_OWN_GENERATED_PASSWORD'
export CAMPUS_KEYS_DIR="$PWD/data/campus-keys"
```

For remote PostgreSQL require TLS certificate validation (`sslmode=verify-full`). No default
production database password, publisher private key or enrollment token is committed.
Provision a publisher once; this refuses to overwrite existing key files:

```sh
mvn -q -f campus-backend/pom.xml exec:java   -Dexec.mainClass=com.beyondnet.campus.CampusAdmin   -Dexec.args="keys data/campus-keys"
java -jar campus-backend/target/campus-backend-0.1.0.jar
```

Run from the repository root; the service binds only `127.0.0.1:8082`. It creates the campus
tables, starts with no records, and requires explicit publisher files. Backup the private
publisher key and the campus database. Losing the key requires an explicit trust migration.
For Android access, the institution/operator must supply an approved HTTPS reverse proxy to
this loopback service. Configure request-body limits, timeouts, access logging/privacy and
per-client rate limiting there. The application enforces token/IP limits too, but sees the
proxy IP and does not trust arbitrary forwarded headers. Keep enrollment/admin tools local.

## Enroll and configure a student

Verify eligibility through the institution's process first. Enrollment is an operator action,
not public self-signup. In another terminal with the same environment:

```sh
mvn -q -f campus-backend/pom.xml exec:java   -Dexec.mainClass=com.beyondnet.campus.CampusAdmin   -Dexec.args="enroll student-id data/student-token.txt"
```

The 30-day token is written only to that private file. Deliver it securely to that student.
Re-enrolling the same ID rotates the credential. An existing output file is never overwritten.
In the Android app open **Open Campus information** from the sign-in screen, or the **Campus** tab, then **Set up Campus**, enter the approved HTTPS origin,
`data/campus-keys/publisher-public.txt` public key and enrollment token. Verify the public key
with staff independently; never accept trust just from Bluetooth advertising or a random URL.
Bank setup and account history remain separate. Tap **Refresh offline information** while
connected, then turn off internet and search cached public information. Expired content is
rejected; an empty corpus remains empty.

Revoke a campus credential:

```sh
mvn -q -f campus-backend/pom.xml exec:java   -Dexec.mainClass=com.beyondnet.campus.CampusAdmin -Dexec.args="revoke student-id"
```

## Publish approved public information

The default corpus is intentionally empty. Prepare a UTF-8 JSON array using the schema at
`contracts/public-records.schema.json`. Each record needs its real approving source and Unix
update/expiry times. Never put private student records in this cache.

```sh
mvn -q -f campus-backend/pom.xml exec:java   -Dexec.mainClass=com.beyondnet.campus.CampusAdmin   -Dexec.args="publish /absolute/path/approved-public-records.json"
```

Publishing validates the entire input before replacing the corpus in one transaction. It
accepts at most 50 records and 64 KiB. Publishing `[]` intentionally empties the corpus.
The signer refuses to return an oversized search result; choose short snippets, not documents.

## Bank gateway credentials

On the bank computer, the existing loopback-only operator API accepts
`POST /api/admin/gateways` with `{ "id": "library", "expires_at": <Unix seconds> }` and
operator authorization. Expiry is 60 seconds to 31 days in the future. It returns a one-time
random token and permissions `packet:submit`, `mailbox:recover`. Provision that token securely;
never put the operator key, account password, bank private key or payment PIN on a gateway.
Use it only with `/api/gateway/packets` and `/api/gateway/mailbox/{cap}`. Reprovisioning the
same ID rotates it. `POST /api/admin/gateways/{id}/revoke` revokes it immediately at the bank.
These APIs do not create a BLE gateway certificate; that integration remains pending.

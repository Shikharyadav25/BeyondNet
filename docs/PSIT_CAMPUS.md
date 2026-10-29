# PSIT Kanpur Campus · 1.5.1 (build 21)

This is a PSIT-named **demonstration deployment**, not a connection to PSIT's ERP or an official college service. It uses independent Campus identities. Payment accounts, PINs and the payment relay remain separate.

## Start the server

Use the `feat/campus-mesh` branch. Install Java **21 JDK**, Maven 3.6.3+, PostgreSQL 17+ and Python 3. On Linux, set `BEYONDNET_PG_BIN` to PostgreSQL's bin directory (for example `/usr/lib/postgresql/17/bin`). macOS Homebrew PostgreSQL paths are detected automatically. Existing managed PostgreSQL can be selected using `CAMPUS_DB_CONFIG` and `CAMPUS_DB_SCHEMA`.

From the repository root:

```sh
mvn -f backend/pom.xml package
./start-campus.sh
```

The campus process binds to loopback on **8090**, uses schema `campus_psit`, and keeps its process lock and operator credential in `data/campus-psit/`. It does not start the bank, bank WebSocket service or payment controller. The bank can run concurrently on **8080** with `./start-bank.sh`. PostgreSQL may be shared, with separate schemas; for a fully separate database, supply `CAMPUS_DB_CONFIG=/absolute/path/to/campus-postgres.properties` before starting. Never point campus at the bank's schema or data directory.

A second terminal provisions the demo roster:

```sh
python3 scripts/setup-psit.py
curl --fail http://127.0.0.1:8090/api/campus-health
```

Provisioning generates five different random passwords in **`data/campus-psit/demo-credentials.json`**, permission 0600. Running it again preserves the existing campus, trust key and passwords. The private credentials are never committed to Git or embedded in the APK or setup QR. If a provisioned campus has lost its private credentials file, restore it; the script refuses to reset its roster silently.

| Campus ID | Select role in app | Groups / posting |
| --- | --- | --- |
| `PSIT-STUDENT-001` | Student | Read all three; write CSE Section A |
| `PSIT-STUDENT-002` | Student | Read all three; write CSE Section A |
| `PSIT-PROF-001` | Professor | Section messages and CSE assignments |
| `PSIT-HOD-001` | Head of department | Section, assignments and PSIT notices |
| `PSIT-ADMIN-001` | Campus authority | Section, assignments and PSIT notices |

These IDs are synthetic and unrelated to actual students or staff. Use the corresponding generated password from the private file. Local console authentication uses **`data/campus-psit/admin-token.txt`**, a different generated operator key. On your trusted machine you can open that file to copy the key. Do not share the operator key with students or place it in a public URL.

For the configured cloud environment, first run:

```sh
source /workspace/.beyondnet-tools/activate.sh
cd /workspace/BeyondNet
```

This selects the local JDK, Maven, PostgreSQL and Maven proxy settings. Future tasks should reuse this isolated checkout; no additional worktree is needed.

## Start a separate ngrok tunnel and generate the QR

Install ngrok and configure your own ngrok account token locally. A bank tunnel may remain on 8080; campus needs a **separate** tunnel to 8090, and your ngrok plan must allow the desired simultaneous endpoints.

```sh
# One-time ngrok setup on your machine; paste your own token locally:
ngrok config add-authtoken YOUR_NGROK_TOKEN
# Leave this terminal open:
./start-campus-tunnel.sh
```

Copy the HTTPS origin shown by ngrok, such as `https://YOUR-CAMPUS.ngrok-free.app`. Open the campus console **on the server machine at localhost port 8090**, enter its operator key, leave the code `PSIT-KANPUR`, and enter the campus HTTPS origin. Select **Generate campus setup QR**. Tunnel clients cannot open the operator console or admin APIs.

Alternatively export a QR image and JSON using the actual tunnel URL:

```sh
python3 scripts/setup-psit.py --public-url https://YOUR-CAMPUS.ngrok-free.app
```

The image is `data/campus-psit/campus-setup.png`. It contains only `type`, version, campus code, HTTPS URL and the SHA-256 fingerprint of the campus signing public key. The fingerprint is obtained from the provisioned authority, never invented from the URL. A bank QR is rejected by Campus, and a Campus QR is rejected by bank setup.

The GitHub-built 1.5.1 APK has a different development signer from 1.5.0 and **cannot install over it**. Use a separate test device or Android user profile. Do not uninstall an enrolled app with unresolved payments. To preserve existing enrollment, rebuild using the original signing keystore on the original build machine; that private key is not stored in this repository. On the test phone, install the new APK, open **Campus → Scan college setup QR** (or **Choose campus QR image**), then select the role and enter the generated ID/password. The URL, campus code and fingerprint fill together. Discovery verifies the fingerprint **before** credentials are sent. Trust only a QR supplied by the deployment operator. Manual entry remains available.

If a free ngrok URL changes, generate a fresh setup QR for new users. Enrolled users select **Renew / update connection**, enter the new HTTPS URL and their password. The app verifies the existing campus signing fingerprint, renews membership and retains its cached queue and cursor. Keep the server's database and keys across restarts to preserve trust.

## Campus features and limits

- Section conversations: students and staff can compose and save encrypted group messages offline.
- Assignments: professors, HODs and campus authorities can publish assignments; students can read them.
- Notices: HODs and authorities can publish priority notices. Unauthorized staff/student posts are rejected by role checks.
- Durable encrypted relay: signed packets are stored in SQLite before sending, checked against campus membership, and forwarded through enrolled nearby phones without giving unrelated group members plaintext access. Server storage is durable in PostgreSQL and repeated submission is idempotent.
- Each peer exchange checks the signed response nonce and maintains one peer identity. A requested packet must match its inventory ID. Replay requests and expired/tampered messages are rejected.
- Internet sync uploads queued packets and retrieves the campus feed using a persisted cursor. Server acceptance means stored by the server, not read by every classmate. After a failure, automatic server calls pause for 30 seconds so nearby delivery can continue; **Sync now** forces a retry.
- Nearby Bluetooth must be enabled on each enrolled phone, with Android nearby/camera permissions as needed. Keep **Campus open in the foreground**. Campus relay pauses on backgrounding and is independent of the payment relay. Message movement depends on real physical encounters; there is no guaranteed delivery or read receipt.
- Membership and messages expire within **24 hours**. Renew online before expiry. Message caches hold at most 512 live packets. This release supports text, not attachments, attendance, ERP single sign-on or assignment submissions. Canteen/vending links open the existing simulated Payments workflow.

### Physical acceptance before classroom use

Enroll two students plus a professor while online. Publish an assignment online and confirm both students decrypt it. Disable internet on the professor and first student; enable Campus Bluetooth on both, keep both screens in Campus, and send a section message. Bring the second student near the first with the professor out of radio range and verify the message arrives. Reconnect a relay to the server, then sync another enrolled phone and verify one copy. Restart a phone and confirm cached messages remain. Test HOD notices, denied student assignment/notice posting, renewal, expired access and changed tunnel URLs. These physical Bluetooth checks are still required even when automated checks pass.

## Verification and APK

```sh
mvn -f backend/pom.xml package
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-test.txt
.venv/bin/python -m pytest -q tests/test_java_bank.py tests/test_campus_server.py
cd mobile
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build apk --release
```

Flutter 3.44+ / Dart 3.12+, Android compile SDK 37 and Flutter's matching NDK are required for an APK. Pushing mobile changes to `feat/campus-mesh` also triggers **Build Campus APK**. It runs analysis and tests, builds release, uploads an Actions artifact and commits `installers/BeyondNet-Android-1.5.1.apk` plus its SHA-256 to the campus branch. A version bump alone does not mean the APK exists: wait for a successful run and the installer commit. Preserve the existing Android signing identity when upgrading enrolled phones; do not uninstall with unresolved payment outcomes.


### Verified 1.5.1 artifact

[Download the built APK from the campus branch](https://github.com/Shikharyadav25/BeyondNet/raw/refs/heads/feat/campus-mesh/installers/BeyondNet-Android-1.5.1.apk).

- [Successful APK workflow](https://github.com/Shikharyadav25/BeyondNet/actions/runs/40903453585): Flutter analysis passed; **142 tests passed, zero skipped/errors**; release build and installer commit succeeded.
- Java: the 51 existing bank/campus tests passed, followed by the two new QR tests (and five campus regression tests). Live HTTP suites: **7 passed** across bank and campus. The setup script was exercised twice, and campus restart retained the authority and accounts.
- APK SHA-256: `69118a888891916552d224a967439ad1139d3c87aeb924899b81243392deabd3`. Its ZIP integrity was verified after fetching the generated installer commit `baeec1e`.
- 1.5.0 signer certificate SHA-256: `17fd7b17e1e09bb580e77590dec9e27f57dddcf0a5fdfaa587821753814f612e`.
- 1.5.1 signer certificate SHA-256: `67d8e5b3d42b211b5f83e089a0085311b3d7d954e4cb049173bfb40f52610300`.
- Physical BLE, camera scanning on hardware and a live user-owned ngrok tunnel remain untested. No ngrok token or original signing keystore was supplied; neither was fabricated. Local Flutter SDK setup remains blocked until the saved `storage.googleapis.com` network addition is applied. Mobile validation and compilation above ran on GitHub Actions.

# Permanent bank hosting without buying a domain

The prepared Render configuration runs the existing Python bank at a provider-assigned HTTPS `onrender.com` URL. The actual hostname is assigned by Render after creation; none has been reserved or deployed yet. HTTPS and WSS use the same host. Phones still relay over BLE and only an online gateway reaches the hosted bank. No APK rebuild is needed solely for hosting.

## Cost and account requirements

`render.yaml` selects a paid Starter web service with a 1 GB persistent disk. The published base compute/storage price checked on 9 October 2026 is about US$7.25/month before taxes and any additional usage. The account owner must approve the price and provide the hosting account. No purchase, service creation, source upload or bank-data upload has been performed by preparing these files.

Do not deploy this SQLite bank on a free ephemeral filesystem. Render's free service cannot attach the required persistent disk and may lose the database/keys on restarts or redeploys. A stable URL alone does not preserve bank identity or records.

## Prepared configuration

- Runtime: Python 3.13.7 and the existing pinned requirements.
- Start: `python scripts/run_cloud_bank.py`, listening on the provider's `PORT`.
- Persistent data: `/var/data/beyondnet` on a disk mounted at `/var/data`.
- Health endpoint: `/api/health`.
- One instance/process for the SQLite ledger and bank controls.
- Existing session/device authentication, operator authentication, encryption, receipts, BLE protocol and bank API remain unchanged.
- Automatic deploys are disabled in the blueprint; review and deploy changes deliberately.

## Account/data migration before using phones

1. Connect a private source repository or container image to Render. Keep `data/`, local credentials, bank keys, operator tokens, build caches and mobile secrets out of source uploads. `.gitignore` already excludes runtime bank data.
2. Review and approve the service cost, then create the service with its persistent disk. Its initial empty disk creates a temporary fresh bank identity; do not enroll phones into it.
3. Once the service and secure shell/file transfer are available, schedule the cutover: pause laptop bank submissions, capture the final SQLite database using SQLite's backup API, and copy the existing `bank-keys.json` and `admin-token.txt` privately. Keep a local recoverable backup. Do not copy a live SQLite file without its WAL state or a proper database backup.
4. Stop the cloud bank process while restoring the three files to `/var/data/beyondnet`, with restrictive file permissions. Use the host's supported deployment/shell controls. Never overwrite an active SQLite database in place.
5. Restart the hosted bank and compare its fingerprint to the laptop's fingerprint before configuring phones. Check the accounts, devices, ledger and payment decisions. Authenticate to its dashboard using the preserved operator key.
6. Point phones to the permanent HTTPS host. An existing installation saves its bank URL; use a tested migration/update flow to change that URL while keeping device keys, history and queues. Do not uninstall phones or assume the existing app has a URL-edit screen. This migration step is required before claiming the hosted bank works with already-enrolled phones.
7. Test online payment, receipt recovery, WSS reconnect, and then two-phone BLE submission. Keep the original laptop bank paused/offline after cutover; two independent ledgers with the same bank keys must not process payments concurrently.

Initial deployment is not a completed migration. A production payment service would need further operational/security work; this remains a demo bank with demo money.

References:
- https://render.com/docs/deploy-fastapi
- https://render.com/docs/disks
- https://render.com/docs/free
- https://render.com/pricing
- https://render.com/docs/websocket

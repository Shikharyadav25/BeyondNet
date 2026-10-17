# Physical mesh demo: release 1.3.6

Use the same 1.3.6 APK on every Android phone. This release adds indexed Bluetooth response reads so repeated reads cannot consume or mix chunks, plus negotiated MTU support. The bank packet format is unchanged. Older peers use the original BLE characteristic; versions before 1.3.5 do not support the approval flow.

## Before turning internet off

1. Start the Java bank and ngrok. Confirm the public bank URL works on each phone while online.
2. Sign in to the same bank on each phone. Each phone needs its own enrolled device identity. Set the sender's six-digit payment PIN and add demo money.
3. Open BeyondNet Nearby on each phone and enable Nearby relay. Allow Bluetooth/Nearby permissions. On Android 10–11, also allow Location and turn Location on. On Android 13+, allow notifications to see relay requests in the notification drawer.
4. Keep Bluetooth on and battery restrictions relaxed for the demo. Leave the app visible on each phone for the first test.
5. Add or scan the merchant's identity while online, then make one small online payment to establish that accounts, bank URL and receipts work.

## Three phones

| Phone | Role in this test | Internet | Bluetooth / Nearby relay |
|---|---|---|---|
| A | Sender | Off | On / On |
| B | Intermediate relay | Off | On / On |
| C | Gateway | On | On / On |

Arrange A near B and B near C. To demonstrate that B is necessary, keep A out of C's Bluetooth range or restrict the allowed peer IDs in Device settings. A bank/server laptop only needs internet; it does not need Bluetooth range.

1. On A, scan for nearby phones. B should appear with its verified name and bank status. Tap **Connect**, then send a small payment to a known recipient.
2. B gets **Relay approval requested**. Tap the notification, open **Nearby**, and choose **Allow relay**. Until B accepts, A keeps its original packet and no custody success is claimed.
3. Because B is offline, its Nearby screen shows the accepted encrypted request under **Choose the next phone**. Select C. B offers the packet to C; C receives its own approval notification.
4. On C, allow the request. Since C can reach the bank, it submits the packet automatically. The bank checks the sender's signature, PIN, expiry, balance and duplicate payment ID before recording a paid or rejected result.
5. Check the bank Payments and Ledger views. On A, the signed result may return through nearby exchange. To test direct recovery, reconnect A to the internet: its own registered device ID is used to fetch queued encrypted receipts from the bank through WebSocket or `/api/receipts/{device_id}`. Check A's Activity screen for the bank reference.

For four phones, keep A, B and C offline and put D online. B approves and selects C; C approves and selects D; D approves and submits. The payment packet permits up to four hops, including the sender-to-first-relay transfer.

## What each state means

| State | Meaning |
|---|---|
| Request waiting for approval | Another phone offered an encrypted packet. No transfer custody was acknowledged yet. |
| Relayed / stored | A phone durably accepted a packet. Settlement is still unknown. |
| Paid or rejected with a signed bank receipt | The bank made and stored the financial decision. |

The 10-minute deadline applies to the original payment authorization. It is not an expected processing delay. If the bank does not receive the request before expiry, it rejects an uncommitted payment. A later retry of an already committed payment recovers the earlier outcome without another debit.

## If a phone is missing or Connect fails

- Check the exact APK version on each phone and ensure Nearby relay is enabled on each. Android 10–11 needs Location enabled for discovery.
- Move phones close for initial discovery, then arrange the chain. A displayed peer can disappear if advertising stops or the radio changes state; scan again.
- A Bluetooth write error with status 133 comes from Android's GATT connection. The app pauses its own scan during a transfer and retries a manual connection once. If it persists, toggle Bluetooth off/on on the two affected phones and restart Nearby relay.
- Keep all phone clocks within two minutes. Signed peer requests outside that window are rejected.
- On Android 13+, granting notifications makes the approval alert visible. Pending requests remain visible in the app's Nearby screen even if notification permission is denied.
- A phone must support BLE advertising as well as scanning. The Device/Nearby screen reports when the hardware cannot relay.

## Evidence and limits

Software tests cover a four-node consent path, legacy routing compatibility, loop avoidance and durable storage. Android build checks cover compilation. Physical radio performance, operating-system scheduling and the exact handset combination still require a real-device run. Bank receipts are stored for a seven-day delivery window; reconnect within that window to retrieve them directly.

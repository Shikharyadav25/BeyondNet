# Free fixed-address tunnel

Ngrok forwards a public HTTPS/WSS address to the existing bank on this laptop. It does not host the bank or move its database. No paid plan is required for the assigned development domain.

## This laptop's verified address

`https://sublime-penalty-helper.ngrok-free.dev`

Bank fingerprint verified on 9 October 2026:

`2f51ebea827536d3feba922adf6e817e8ec4d95e0b226c2641f827b3ea85c855`

The domain belongs to the currently configured ngrok account. Another account receives a different assigned domain. Starting this account's tunnel again uses its assigned domain; account changes or provider restrictions can affect availability.

## Start again

1. Start `Start-Bank.command` and keep its window open.
2. Start `Start-Ngrok.command` and keep its window open. Only start one tunnel for this endpoint. Alternatively run `ngrok http http://127.0.0.1:8080 --inspect=false` in a separate terminal.
3. Use the HTTPS address printed by ngrok. The bank dashboard is at that address, or locally at `http://localhost:8080`. The same operator key unlocks both.

Ngrok is already installed and authenticated on this Mac. On another computer, install it from https://ngrok.com/download and configure your own account's authentication token privately using the provider's instructions. Tokens are not included in this source bundle.

## Update an existing phone

Connect the phone to the internet. Open **Settings → Online setup → Renew login / update bank URL**. Replace the URL with the address above, keep the same account and trusted fingerprint, enter that account's password and submit. Repeat on every participating phone. Preserve the app installation and its device keys/history; do not uninstall to change the URL.

## Availability and checks

The laptop must be awake and online, with the bank and tunnel running. Disconnects delay bank confirmation; only a verified bank receipt means a payment completed. Keep the local `data/` directory private and backed up.

Verified: the public health API returned the existing bank fingerprint over HTTPS, and `/api/live` accepted a WebSocket upgrade (HTTP 101). These transport checks do not prove a new physical two-phone payment; run that demo after updating both phones.

The free plan currently allows 1 GB outbound transfer and 20,000 HTTP requests per month. The dashboard polls frequently, so close remote dashboard tabs when finished; use the local dashboard on the laptop where possible. Free browser visits may show a warning page: select **Visit Site** to continue. API requests are not subject to that browser warning.

Traffic inspection is disabled in the launcher to avoid storing payment/login request bodies in the local ngrok inspector. Existing bank authentication and fingerprint verification still apply.

Limits: https://ngrok.com/docs/pricing-limits/free-plan-limits

# dsh-duo-relay

A tiny rendezvous between your dsh (Host) and your phones (Devices). Both connect out to it, so nothing needs a public
address. It is **zero-trust**:

- Message bodies are AES-256-GCM sealed end to end; the relay forwards ciphertext.
- Rooms are trust-on-first-use: the first Host registers `SHA-256(relay-auth)`. The relay never learns the pairing secret,
  and `relay-auth` is derived from it with HKDF.
- Pushes carry a generic alert plus a sealed blob that the phone's Notification Service Extension decrypts.

## Deploy

### Cloudflare Workers (free tier, one command)

```bash
npm install
npx wrangler deploy
```

Use the printed `https://dsh-duo-relay.<you>.workers.dev` as the plugin's `relay`.

### Any server (Node 22.18+ or Docker)

```bash
npm install --omit=dev
PORT=8787 DATA_DIR=./data node src/node.ts
```

```bash
docker build -t dsh-duo-relay .
```

Put TLS in front of it (Caddy, Fly.io, Render, a load balancer).

## Push notifications (optional)

Create an APNs key (Certificates, IDs & Profiles → Keys → Apple Push Notifications service) and set:

| Variable | Value |
|---|---|
| `APNS_KEY_ID` | Key ID |
| `APNS_TEAM_ID` | Team ID |
| `APNS_PRIVATE_KEY` | Contents of `AuthKey_XXXX.p8` (`\n` escapes are accepted) |
| `APNS_TOPIC` | App bundle ID (default `ai.deepseek.harness.duo`) |

On Cloudflare, use `npx wrangler secret put APNS_PRIVATE_KEY` (and the others). Without these, the relay still works.
Phones get live updates while the app is open, and local notifications for other sessions.

Pushes go only to registered devices that are not connected at that moment; the app hangs up when it goes to the
background. Tokens that APNs rejects permanently are dropped.

`GET /healthz` reports whether pushes are configured.

## Test

```bash
npm test
```

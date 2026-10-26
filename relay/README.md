# dsh-duo-relay

A tiny rendezvous between your dsh (Host) and your phones (Devices). Both connect out to it, so nothing needs a public
address. It is **zero-trust**:

- Message bodies are AES-256-GCM sealed end to end; the relay forwards ciphertext.
- Rooms are trust-on-first-use: the first Host registers `SHA-256(relay-auth)`. The relay never learns the pairing secret,
  and `relay-auth` is derived from it with HKDF.
- It holds no secrets at all. Push notifications don't go through it: each person's dsh plugin sends them straight to
  Apple with the key of the team that signed their app (see `ios/scripts/install.sh`).

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

## Test

```bash
npm test
```

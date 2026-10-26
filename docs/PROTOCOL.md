# DSH Duo wire protocol (v1)

Three parties take part:

| Party | Lives | Role |
|---|---|---|
| **Host** | `dsh-plugin-duo-remote`, inside the `dsh` process | Owns the dsh session API; dials out to the relay |
| **Relay** | `relay/` (Node or Cloudflare Worker), public | Forwards opaque ciphertext between Host and Devices; holds no secrets |
| **Device** | `ios/` app (and its Notification Service Extension) | The phone |

Neither the Host nor the Device accepts inbound connections, so no VPN, port
forwarding or public IP is needed. The relay never sees plaintext.

## 1. Pairing

The Host keeps one pairing record in `$DSH_HOME/duo-remote/pairing.json`:

```json
{ "roomId": "<22-char base64url>", "secret": "<43-char base64url of 32 bytes>", "relay": "https://relay.example" }
```

It is shown as a QR code (terminal, `/duo-pair` command, and `dsh-duo pair`)
encoding:

```
dshduo://pair?v=1&r=<relay URL>&i=<roomId>&k=<secret>&n=<host name>
```

Rotating the secret (`dsh-duo rotate`) un-pairs every device.

## 2. Key derivation

All keys use HKDF-SHA256 with `salt = "dsh-duo"` and a 32-byte output:

| `info` | Use |
|---|---|
| `relay-auth` | Room credential presented to the relay (hex). The relay stores only `SHA-256(relay-auth)`. |
| `e2e-v1` | AES-256-GCM key for every frame body |

Sealed body = `base64( nonce(12) ‖ ciphertext ‖ tag(16) )`, AAD = `dsh-duo/v1`.
This is exactly CryptoKit's `AES.GCM.SealedBox.combined` layout.

## 3. Relay transport

WebSocket: `wss://<relay>/v1/rooms/<roomId>?role=host|device&auth=<hex>[&device=<id>]`

The first Host connection registers the room (trust on first use). Devices are
refused until the room exists. A second Host replaces the first.

Relay frames are JSON text:

| Direction | Frame |
|---|---|
| Device → Relay | `{ "t": "msg", "d": "<sealed>" }` → delivered to Host as `{ "t": "msg", "from": "<deviceId>", "d" }` |
| Host → Relay | `{ "t": "msg", "to"?: "<deviceId>", "d" }` → delivered to that Device (or all) as `{ "t": "msg", "d" }` |
| Relay → Host | `{ "t": "device", "id", "online": bool }` |
| Relay → Device | `{ "t": "host", "online": bool }` |
| any | `{ "t": "ping" }` → `{ "t": "pong" }` |

HTTP `POST /v1/rooms/<roomId>/send` with `Authorization: Bearer <relay-auth>`
and body `{ "device": "<id>", "d": "<sealed>" }` delivers one message to the
Host without a socket (used by notification quick replies). `202` on delivery,
`503` when the Host is offline.

## 3a. Push notifications

The relay is not involved. A Device registers its APNs token with its Host (`push.register`,
sealed like any request). The Host holds the APNs key of the team that signed that copy of
the app (`$DSH_HOME/duo-remote/apns.json`, written by `ios/scripts/install.sh`) and sends
pushes directly to Apple for registered Devices the relay reports offline. The APNs payload
carries only `{"aps":{"alert":{"title":"DeepSeek Harness","body":"New activity"},"mutable-content":1,...},"e":"<sealed>"}`;
the Notification Service Extension decrypts `e` and rewrites the alert.

## 4. Application messages (inside `d`)

Every decrypted body is one JSON object.

Requests (Device → Host): `{ "id": <int>, "op": "<name>", ...params }`
Responses (Host → Device): `{ "re": <id>, "ok": true, "value": ... }` or `{ "re": <id>, "ok": false, "error": { "code", "message" } }`
Events (Host → Device): `{ "ev": "<name>", ... }`

### Requests

| op | params | value |
|---|---|---|
| `hello` | `device: { name, model }` | `{ host, version, presets, workspaces, sessions, push: { enabled, topic? } }` |
| `sessions.list` | — | `Session[]` |
| `workspaces.list` | — | `Workspace[]` |
| `workspaces.add` | `path` | `Workspace` |
| `fs.list` | `path?` | `{ path, home, parent?, entries: [{ name, path, hidden }] }` |
| `session.create` | `workspaceId?`, `cwd?`, `preset?` | `Session` |
| `session.open` | `sessionId` | `{ session, items: Item[], hasMore }` then `session.items`/`session.live` events |
| `session.close` | `sessionId` | — |
| `session.prompt` | `sessionId`, `text`, `mode: "queue"\|"steer"` | `{ kind: "prompt" \| "command" }` |
| `session.cancel` | `sessionId` | — |
| `session.model` | `sessionId`, `provider`, `model`, `effort?` | `ModelSelection` |
| `session.preset` | `sessionId`, `preset` | `{ preset }` |
| `session.rename` | `sessionId`, `title` | — |
| `models.catalog` | — | `{ default, groups: [{ id, name, models: [{ id, name, description?, efforts: [{ id, name }], defaultEffort? }] }] }` |
| `commands.list` | `sessionId` | `[{ name, description, hint?, kind: "command"\|"skill" }]` |
| `push.register` | `token`, `env: "sandbox"\|"production"`, `topic` | `{ enabled }` |
| `question.answer` | `sessionId`, `callId`, `answers: [{ id, selected: [], custom? }]` | `{ accepted }` |

### Events

| ev | fields |
|---|---|
| `sessions.upsert` | `session: Session` |
| `sessions.remove` | `sessionId` |
| `workspaces.changed` | `workspaces: Workspace[]` |
| `session.items` | `sessionId`, `items: Item[]` (append or replace by `id`) |
| `session.live` | `sessionId`, `live: LiveAttempt \| null` (streaming assistant output) |
| `question` | `sessionId`, `callId`, `questions: Question[]`, `title` |
| `question.resolved` | `sessionId`, `callId` |
| `turn.finished` | `sessionId`, `title`, `summary`, `reason` |

### Shapes

```ts
Session = { id, title, updatedAt, running, blank, cwd?, workspaceId?, preset?, model?: { provider, model, effort? }, questions: number, parentId? }
Workspace = { id, title, path, sessionIds: string[] }
Item =
  | { id, kind: "user", text, time }
  | { id, kind: "thinking", text, time, turn }
  | { id, kind: "text", text, time, turn }
  | { id, kind: "tool", callId, name, args, time, turn, status: "running"|"ok"|"error", result?, }
  | { id, kind: "notice", text, time, level: "info"|"error" }
  | { id, kind: "turn", time, turn, reason }
LiveAttempt = { attemptId, thinking, text, tools: [{ id, name, args }] }
Question = { id, question, header?, detail?, options: [{ label, description? }], multiSelect, intent? }
```

Push payload (sealed in `e`): `{ kind: "turn"|"question", sessionId, title, body, callId?, questions? }`

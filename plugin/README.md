# dsh-plugin-duo-remote

Companion bundle that lets the **DSH Duo** iPhone app drive this DeepSeek Harness from anywhere.

The plugin opens an outbound WebSocket to a relay and speaks for an in-process owner Peer through dsh's own Typert
Gateway. The phone therefore gets the same API, validation and behavior as the dsh Web client, including `session/*`,
`agentPresets/*`, `commands/*`, `skills/*`, `workspace/*`, `directoryPicker/*` and `userQuestions/*`. Every message is
end-to-end encrypted. See [`docs/PROTOCOL.md`](../docs/PROTOCOL.md).

## Install

```bash
dsh plugin add dsh-plugin-duo-remote
```

It connects to the public relay `https://dsh-duo-relay.cloudflare-hybrid809.workers.dev` by default; that relay only
forwards ciphertext. To use your own relay (see [`relay/`](../relay)), set an environment variable:

```bash
export DSH_DUO_RELAY=https://dsh-duo-relay.example.workers.dev
```

or configure the row in your profile's `cordis.patch.yml`:

```yaml
- id: duo-remote
  name: dsh-plugin-duo-remote
  config:
    relay: https://dsh-duo-relay.example.workers.dev
    hostName: Studio Mac        # name the phone shows (default: host name)
    holdQuestions: true          # keep DeepSeek's questions open for the phone
    historyMessages: 200         # messages loaded when a session opens
```

Start dsh (`dsh web`, or the desktop app). The first time, a pairing QR code prints in the terminal.

## Pairing

| | |
|---|---|
| `dsh-duo pair` | Print the pairing QR code and link |
| `dsh-duo rotate` | New secret: unpairs every phone |
| `dsh-duo status` | Relay, room and pairing file |
| `/duo-pair` | In any dsh session: connection status (`/duo-pair qr` prints the QR in the dsh terminal) |

The QR code carries the room secret, so the plugin never writes it into a session log. The pairing record lives in
`$DSH_HOME/duo-remote/pairing.json` (mode 0600).

## What it does on the Host

- Mirrors the session list, titles, modes, models and pending questions from `session/list`, the `session/control`
  projection stream and the `api-session/*` events, and workspaces from `workspace/follow`.
- Follows open sessions with `session/follow` (assistant streams included). It projects the log onto a small item
  vocabulary (user, thinking, text, tool, notice, turn) and coalesces streaming deltas to about 12 frames per second.
- Holds `user-questions/request` for the phone (prepended, racing any Web client) once a phone has paired, and answers
  continued questions through `userQuestions/answer`.
- On a running → idle transition, sends `turn.finished` to connected phones and an encrypted push to the others.
- Sends push notifications itself, straight to Apple over HTTP/2, to phones that registered a token and aren't
  connected. It uses the key of the team that signed that copy of the app, which `ios/scripts/install.sh --apns-key`
  stores in `$DSH_HOME/duo-remote/apns.json`. The relay never holds Apple credentials.
- `session.prompt` that starts with `/` goes through `commands/execute` first, the same way the Web composer does.

## Develop

```bash
npm install
npm test
node dev/demo-host.ts --relay http://127.0.0.1:8787
```

`npm test` is an end-to-end test: the real relay, this plugin on a fake Host, and a simulated phone. The demo Host
simulates dsh for app development without a DeepSeek key.

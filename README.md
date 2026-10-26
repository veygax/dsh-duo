# DSH Duo

A native SwiftUI remote for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`), designed for
**iPhone Duo** and following Apple's [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
guidelines. Install the companion plugin on the machine that runs dsh, scan a QR code, and drive your sessions from
anywhere: no VPN, no port forwarding, end-to-end encrypted.

```
 iPhone Duo app  ──wss──▶  relay (forwards ciphertext, sends APNs)  ◀──wss──  dsh + dsh-plugin-duo-remote
```

Both ends dial **out** to the relay, so neither needs a public address. Every message is sealed with AES-256-GCM using a
key that only the phone and your dsh share (it travels in the pairing QR code). The relay sees routing envelopes and
ciphertext only. See [docs/PROTOCOL.md](docs/PROTOCOL.md).

| Folder | What it is |
|---|---|
| [`ios/`](ios) | SwiftUI app, Notification Service Extension, unit tests (XcodeGen `project.yml` + generated `.xcodeproj`) |
| [`plugin/`](plugin) | `dsh-plugin-duo-remote`: the dsh bundle the phone talks to |
| [`relay/`](relay) | Zero-trust WebSocket relay + APNs sender (Node or Cloudflare Workers) |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | Pairing, key derivation, relay frames, app messages |

## What the app does

- **Sessions on the left.** A `NavigationSplitView` sidebar groups sessions by workspace with live running and
  waiting-for-you badges, search, swipe-to-rename and context menus. On the inner display it sits beside the open session;
  on the outer display it collapses to one column.
- **Full screen.** Hides the sidebar, bars and status bar so the conversation spans the display. On the inner display
  the session becomes an `ArrangementView` of the conversation and a live activity inspector, which keeps each pane on
  its own side of the fold.
- **Models and thinking levels.** A composer chip lists every provider's models from the Host's catalog, with the
  model's reasoning efforts (for example Low / Medium / High / Max).
- **Thinking, tool calls and messages.** Streaming thinking (collapsible), tool calls with arguments, results and status,
  Markdown replies with copyable code blocks, and command output.
- **Regular, PTC, Minimal and Creator modes.** These map to dsh's `standard`, `ptc`, `minimal` and `cordis` agent
  presets, plus any custom presets. dsh fixes a session's mode at its first turn, so picking a new mode on a started
  session offers a new session in the same folder.
- **New workspaces.** Browse folders on the Mac and register one.
- **Slash commands, listed automatically.** Type `/` (or tap the slash button) to get the session's dsh commands and
  skills, filtered as you type. Commands run on the Host without a model turn.
- **Notifications.** You're notified when a turn finishes or when DeepSeek asks a question, with inline **Reply** /
  **Answer** actions. In the foreground these are local notifications for sessions you aren't viewing. In the
  background they arrive as relay APNs pushes that the Notification Service Extension decrypts on the phone.
- **Questions.** DeepSeek's `ask_user_question` appears as a card above the composer. A single choice answers in one
  tap.
- **Haptics on every button.** Taps, selections, success, warning, error, and a two-beat "attention" pattern for
  questions.

### iPhone Duo specifics

- Standard toolbars throughout, so the system places controls on the vertical side axis. Items use `Label` (title +
  symbol), `ToolbarItemGroup`, `.visibilityPriority(.high)` for primary actions, and `ToolbarOverflowMenu` instead of a
  custom "…" menu.
- `.toolbarVerticalCompressionBehavior(.prefersToolbarItems)` on the session screen, which is task-oriented.
- `ArrangementView` for the full-screen session and the onboarding screen; navigation stays outside it.
- `ReservedRegion` (via `GeometryProxy.reservedRegions(kind:)`) in `FoldAware`, which keeps custom floating components
  (the composer, banners, the full-screen exit button) clear of the fold and the active inner camera.
- Grids use an even number of columns (mode cards, question options) so they divide cleanly at the fold.
- Size-class driven layout with no fixed widths; deployment target iOS 27.1.

## Quick start

1. **Relay.** Deploy once, anywhere public. See [relay/README.md](relay/README.md). The Cloudflare Workers free tier works:

   ```bash
   cd relay && npm install && npx wrangler deploy
   ```

2. **Plugin.** On the machine running dsh:

   ```bash
   dsh plugin add dsh-plugin-duo-remote
   ```

   Then set the relay (env or profile patch, see [plugin/README.md](plugin/README.md)) and start dsh:

   ```bash
   DSH_DUO_RELAY=https://dsh-duo-relay.<you>.workers.dev dsh web
   ```

   A pairing QR code prints in the terminal; `dsh-duo pair` shows it again.

3. **App.** Open `ios/DSHDuo.xcodeproj`, set your team, and run on iPhone Duo. Scan the QR code, or paste the link.

## Developing without a DeepSeek key

The plugin ships a demo Host that simulates dsh (streaming replies, tool calls, questions, commands) around the real
plugin:

```bash
cd relay && npm install && npm start
```

```bash
cd plugin && npm install && node dev/demo-host.ts --relay http://127.0.0.1:8787
```

Open the printed `dshduo://` link in the simulator: `xcrun simctl openurl booted '<link>'`.

## Tests

```bash
cd relay && npm test
```

```bash
cd plugin && npm test
```

```bash
cd ios && xcodebuild -project DSHDuo.xcodeproj -scheme DSHDuo -destination 'platform=iOS Simulator,name=iPhone Duo' test
```

The plugin's end-to-end test runs the real relay, the plugin on a fake dsh Host, and a simulated phone over the sealed
protocol. The iOS tests include crypto interop with a box sealed by the Node plugin.

// DSH Duo "iPhone" page for the dsh Web and Desktop apps.
// Served by the host as /plugins/dsh-plugin-duo-remote/client.js; it may only require
// the shell's seed modules (react, react/jsx-runtime, @deepseek-ai/dsh-client-ui-primitives).
window.__ModuleLoader__.load({
  id: 'dsh-plugin-duo-remote',
  factory: (require) => {
    const React = require('react')
    const h = React.createElement
    const { useCallback, useEffect, useRef, useState } = React

    const NS = 'duo-remote'
    const PANEL_ID = 'duo-remote'
    const POLL_MS = 2000

    // ── Remote contribution (mirrors src/panel.ts MANIFEST) ──────────────────
    const identity = (value) => value
    const strictSchema = { parse: identity }
    const codec = (type) => ({
      mode: 'strict', typeSymbol: 'dsh-plugin-duo-remote#' + type, schema: strictSchema, create: () => strictSchema,
    })
    const descriptor = (method, result) => ({
      id: 'dsh-plugin-duo-remote#duoRemote/' + method,
      service: 'duoRemote',
      namespace: 'duoRemote',
      method,
      invocation: { kind: 'direct' },
      parameters: [],
      result: codec(result),
    })
    const CONTRIBUTION = {
      package: 'dsh-plugin-duo-remote',
      descriptors: [
        descriptor('overview', 'Overview'),
        descriptor('pairingCode', 'PairingCode'),
        descriptor('unpairAll', 'Overview'),
      ],
    }

    // ── Copy ─────────────────────────────────────────────────────────────────
    const en = {
      nav: 'iPhone',
      title: 'iPhone',
      intro: 'Use DeepSeek Harness from DSH Duo on your iPhone, from anywhere. No VPN, no port forwarding.',
      back: 'Back to conversation',
      loading: 'Loading…',
      pairTitle: 'Pair your iPhone',
      step1: 'Open DSH Duo on your iPhone.',
      step2: 'Tap Scan Pairing Code.',
      step3: 'Point the camera at this code.',
      orPaste: 'Or copy the link here and tap Paste in DSH Duo; Universal Clipboard carries it to your iPhone.',
      copyLink: 'Copy Link',
      copied: 'Copied',
      waiting: 'Waiting for your iPhone…',
      secret: 'This code holds the key that encrypts everything between your iPhone and this Mac. Only scan it with phones you own.',
      connectedTitle: 'Connected',
      connectedTo: (name) => 'DSH Duo on ' + name + ' is connected. Your sessions are on your iPhone now.',
      phonesTitle: 'Paired phones',
      online: 'Connected now',
      lastSeen: (when) => 'Last seen ' + when,
      notificationsOn: 'Notifications on',
      notificationsOff: 'Notifications only while open',
      pairAnother: 'Pair Another iPhone',
      hideCode: 'Hide Pairing Code',
      pushTitle: 'Notifications when the app is closed',
      pushOn: (topic) => 'On. This Mac sends them with your own Apple push key (' + topic + ').',
      pushOff: 'Off. While DSH Duo is open you still get notified about other sessions. To get them when it is closed, sign the app with ios/scripts/install.sh --apns-key.',
      relayTitle: 'Connection',
      relayOn: (host) => 'Connected to the relay at ' + host + '. It only forwards encrypted messages.',
      relayOff: (host) => 'Reconnecting to the relay at ' + host + '…',
      unpair: 'Unpair All Phones',
      unpairConfirm: 'Click again to unpair every phone',
      unpairHint: 'Makes a new pairing code. Every phone loses access right away and has to scan again.',
      failed: 'Could not reach the DSH Duo plugin: ',
    }
    const zh = {
      ...en,
      nav: 'iPhone',
      title: 'iPhone',
      intro: '在 iPhone 上用 DSH Duo 随时随地使用 DeepSeek Harness，无需 VPN 或端口转发。',
      back: '返回会话',
      loading: '正在读取…',
      pairTitle: '配对你的 iPhone',
      step1: '在 iPhone 上打开 DSH Duo。',
      step2: '轻点「扫描配对码」。',
      step3: '将相机对准这个二维码。',
      orPaste: '也可以在这里复制链接，再在 DSH Duo 中轻点「粘贴」；通用剪贴板会把它带到 iPhone。',
      copyLink: '复制链接',
      copied: '已复制',
      waiting: '正在等待你的 iPhone…',
      secret: '这个二维码包含加密 iPhone 与这台电脑之间所有内容的密钥，只用你自己的手机扫描。',
      connectedTitle: '已连接',
      connectedTo: (name) => name + ' 上的 DSH Duo 已连接，现在可以在 iPhone 上看到你的会话。',
      phonesTitle: '已配对的手机',
      online: '当前已连接',
      lastSeen: (when) => '上次连接：' + when,
      notificationsOn: '通知已开启',
      notificationsOff: '仅在打开时通知',
      pairAnother: '配对另一台 iPhone',
      hideCode: '隐藏配对码',
      pushTitle: 'App 关闭时的通知',
      pushOn: (topic) => '已开启。这台电脑使用你自己的 Apple 推送密钥发送（' + topic + '）。',
      pushOff: '未开启。DSH Duo 打开时仍会提醒其他会话的动态；如需在关闭时也收到通知，请用 ios/scripts/install.sh --apns-key 签名 App。',
      relayTitle: '连接',
      relayOn: (host) => '已连接到中继 ' + host + '，它只转发加密消息。',
      relayOff: (host) => '正在重新连接中继 ' + host + '…',
      unpair: '取消所有手机的配对',
      unpairConfirm: '再点一次以取消所有手机的配对',
      unpairHint: '生成新的配对码。所有手机会立即失去访问权限，需要重新扫描。',
      failed: '无法连接 DSH Duo 插件：',
    }

    // ── Styles (dsh design tokens) ───────────────────────────────────────────
    const css = `
.DUO_page { height: 100%; overflow-y: auto; padding: 24px 32px 48px; box-sizing: border-box; color: var(--dsw-alias-label-primary); }
.DUO_inner { max-width: 760px; margin: 0 auto; display: flex; flex-direction: column; gap: 16px; }
.DUO_back { align-self: flex-start; background: none; border: 0; padding: 4px 0; color: var(--dsw-alias-label-secondary); cursor: pointer; font: inherit; font-size: 13px; }
.DUO_back:hover { color: var(--dsw-alias-label-primary); }
.DUO_title { font-size: 22px; font-weight: 600; margin: 4px 0 0; }
.DUO_intro { color: var(--dsw-alias-label-secondary); margin: 0; line-height: 1.5; }
.DUO_card { background: var(--dsw-alias-bg-layer-1); border: 1px solid var(--dsw-alias-border-l2); border-radius: 16px; padding: 20px; display: flex; flex-direction: column; gap: 12px; }
.DUO_cardTitle { font-size: 15px; font-weight: 600; margin: 0; }
.DUO_muted { color: var(--dsw-alias-label-secondary); font-size: 13px; line-height: 1.5; margin: 0; }
.DUO_pair { display: flex; gap: 24px; align-items: center; flex-wrap: wrap; }
.DUO_qr { width: 220px; height: 220px; padding: 12px; background: #fff; border-radius: 14px; box-shadow: var(--dsw-shadow-lv1); flex: none; }
.DUO_qr img { width: 100%; height: 100%; display: block; image-rendering: pixelated; }
.DUO_steps { flex: 1; min-width: 240px; display: flex; flex-direction: column; gap: 10px; }
.DUO_steps ol { margin: 0; padding-left: 20px; display: flex; flex-direction: column; gap: 8px; line-height: 1.4; }
.DUO_row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.DUO_button { border: 1px solid var(--dsw-alias-border-l2); background: var(--dsw-alias-bg-layer-1); color: var(--dsw-alias-label-primary); border-radius: 999px; padding: 6px 14px; font: inherit; font-size: 13px; cursor: pointer; }
.DUO_button:hover { background: var(--dsw-alias-interactive-bg-hover); }
.DUO_primary { background: #4d6bfe; border-color: transparent; color: #fff; font-weight: 500; }
.DUO_primary:hover { background: #4d6bfe; filter: brightness(1.1); }
.DUO_danger { color: var(--dsw-alias-state-error-primary); }
.DUO_dangerArmed, .DUO_dangerArmed:hover { background: #d93a3a; border-color: transparent; color: #fff; font-weight: 500; }
.DUO_waiting { display: flex; gap: 8px; align-items: center; color: var(--dsw-alias-label-secondary); font-size: 13px; }
.DUO_pulse { width: 8px; height: 8px; border-radius: 50%; background: var(--dsw-alias-state-business-primary); animation: DUO_pulse 1.4s ease-in-out infinite; }
@keyframes DUO_pulse { 0%, 100% { opacity: .25 } 50% { opacity: 1 } }
@media (prefers-reduced-motion: reduce) { .DUO_pulse { animation: none } }
.DUO_success { border-color: var(--dsw-alias-state-success-primary); }
.DUO_phone { display: flex; gap: 12px; align-items: center; padding: 10px 0; border-top: 1px solid var(--dsw-alias-border-l1); }
.DUO_phone:first-of-type { border-top: 0; }
.DUO_phoneName { font-weight: 500; }
.DUO_dot { width: 8px; height: 8px; border-radius: 50%; flex: none; background: var(--dsw-alias-label-tertiary); }
.DUO_dotOn { background: var(--dsw-alias-state-success-primary); }
.DUO_badge { margin-left: auto; font-size: 12px; color: var(--dsw-alias-label-secondary); border: 1px solid var(--dsw-alias-border-l2); border-radius: 999px; padding: 2px 8px; white-space: nowrap; }
.DUO_error { color: var(--dsw-alias-state-error-primary); font-size: 13px; margin: 0; }
`
    if (typeof document !== 'undefined') {
      const id = 'dsh-plugin-duo-remote/page.css'
      let tag = document.querySelector('style[data-plugin-css="' + id + '"]')
      if (tag === null) {
        tag = document.createElement('style')
        tag.dataset.plugin = 'dsh-plugin-duo-remote'
        tag.dataset.pluginCss = id
        document.head.appendChild(tag)
      }
      tag.textContent = css
    }

    // ── Pieces ───────────────────────────────────────────────────────────────
    function PhoneIcon(props) {
      const size = props && props.size ? props.size : 16
      return h('svg', { width: size, height: size, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true },
        h('rect', { x: 2.5, y: 1.5, width: 5, height: 13, rx: 1.4, stroke: 'currentColor', strokeWidth: 1.2 }),
        h('rect', { x: 8.5, y: 1.5, width: 5, height: 13, rx: 1.4, stroke: 'currentColor', strokeWidth: 1.2 }))
    }

    function relative(ms, lang) {
      const seconds = Math.round((ms - Date.now()) / 1000)
      const format = new Intl.RelativeTimeFormat(lang, { numeric: 'auto' })
      const units = [['day', 86400], ['hour', 3600], ['minute', 60]]
      for (const [unit, size] of units) if (Math.abs(seconds) >= size) return format.format(Math.round(seconds / size), unit)
      return format.format(0, 'second')
    }

    function hostOf(url) {
      try { return new URL(url).host } catch { return url }
    }

    function PairCode(props) {
      const t = props.t
      const [code, setCode] = useState(null)
      const [copied, setCopied] = useState(false)
      useEffect(() => {
        let live = true
        props.pairingCode().then((value) => { if (live) setCode(value) }, () => undefined)
        return () => { live = false }
      }, [props.generation])
      const copy = () => {
        if (code === null) return
        navigator.clipboard.writeText(code.link).then(() => {
          setCopied(true)
          setTimeout(() => setCopied(false), 1500)
        }, () => undefined)
      }
      return h('div', { className: 'DUO_card' },
        h('h2', { className: 'DUO_cardTitle' }, t.pairTitle),
        h('div', { className: 'DUO_pair' },
          h('div', { className: 'DUO_qr' }, code === null ? null
            : h('img', { alt: 'Pairing code', src: 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(code.svg) })),
          h('div', { className: 'DUO_steps' },
            h('ol', null, h('li', null, t.step1), h('li', null, t.step2), h('li', null, t.step3)),
            h('p', { className: 'DUO_muted' }, t.orPaste),
            h('div', { className: 'DUO_row' },
              h('button', { type: 'button', className: 'DUO_button', onClick: copy, disabled: code === null }, copied ? t.copied : t.copyLink)),
            h('div', { className: 'DUO_waiting', role: 'status' }, h('span', { className: 'DUO_pulse' }), t.waiting))),
        h('p', { className: 'DUO_muted' }, t.secret))
    }

    function Page(props) {
      const t = props.t()
      const lang = props.lang()
      const [overview, setOverview] = useState(null)
      const [error, setError] = useState(null)
      const [showCode, setShowCode] = useState(false)
      const [justPaired, setJustPaired] = useState(null)
      const [armed, setArmed] = useState(false)
      const [generation, setGeneration] = useState(0)
      const knownOnline = useRef(null)

      const refresh = useCallback(() => props.overview().then((value) => {
        setError(null)
        // A phone that comes online while the code is showing has just paired.
        const online = new Set(value.phones.filter((phone) => phone.online).map((phone) => phone.id))
        if (knownOnline.current !== null) {
          const fresh = value.phones.find((phone) => phone.online && !knownOnline.current.has(phone.id))
          if (fresh !== undefined) {
            setJustPaired(fresh.name)
            setShowCode(false)
          }
        }
        knownOnline.current = online
        setOverview(value)
      }, (failure) => setError(String(failure && failure.message ? failure.message : failure))), [])

      useEffect(() => {
        refresh()
        const timer = setInterval(refresh, POLL_MS)
        return () => clearInterval(timer)
      }, [refresh])

      useEffect(() => {
        if (!armed) return
        const timer = setTimeout(() => setArmed(false), 4000)
        return () => clearTimeout(timer)
      }, [armed])

      const unpair = () => {
        if (!armed) {
          setArmed(true)
          return
        }
        setArmed(false)
        props.unpairAll().then((value) => {
          knownOnline.current = new Set()
          setOverview(value)
          setJustPaired(null)
          setShowCode(true)
          setGeneration((n) => n + 1)
        }, (failure) => setError(String(failure && failure.message ? failure.message : failure)))
      }

      const children = [
        h('button', { key: 'back', type: 'button', className: 'DUO_back', onClick: props.back }, '← ' + t.back),
        h('h1', { key: 'title', className: 'DUO_title' }, t.title),
        h('p', { key: 'intro', className: 'DUO_intro' }, t.intro),
      ]
      if (error !== null) children.push(h('p', { key: 'error', className: 'DUO_error', role: 'alert' }, t.failed + error))
      if (overview === null) {
        if (error === null) children.push(h('p', { key: 'loading', className: 'DUO_muted' }, t.loading))
        return h('div', { className: 'DUO_page' }, h('div', { className: 'DUO_inner' }, children))
      }

      const phones = overview.phones
      if (justPaired !== null) {
        children.push(h('div', { key: 'paired', className: 'DUO_card DUO_success', role: 'status' },
          h('h2', { className: 'DUO_cardTitle' }, '✓ ' + t.connectedTitle),
          h('p', { className: 'DUO_muted' }, t.connectedTo(justPaired))))
      }
      if (phones.length === 0 || showCode) {
        children.push(h(PairCode, { key: 'code', t, generation, pairingCode: props.pairingCode }))
      }
      if (phones.length > 0) {
        children.push(h('div', { key: 'phones', className: 'DUO_card' },
          h('h2', { className: 'DUO_cardTitle' }, t.phonesTitle),
          h('div', null, phones.map((phone) => h('div', { key: phone.id, className: 'DUO_phone' },
            h('span', { className: 'DUO_dot' + (phone.online ? ' DUO_dotOn' : '') }),
            h('div', null,
              h('div', { className: 'DUO_phoneName' }, phone.name),
              h('div', { className: 'DUO_muted' }, phone.online ? t.online : t.lastSeen(relative(phone.lastSeen, lang)))),
            h('span', { className: 'DUO_badge' }, phone.notifications && overview.push.enabled ? t.notificationsOn : t.notificationsOff)))),
          h('div', { className: 'DUO_row' },
            h('button', { type: 'button', className: 'DUO_button' + (showCode ? '' : ' DUO_primary'), onClick: () => setShowCode(!showCode) },
              showCode ? t.hideCode : t.pairAnother))))
      }
      children.push(h('div', { key: 'push', className: 'DUO_card' },
        h('h2', { className: 'DUO_cardTitle' }, t.pushTitle),
        h('p', { className: 'DUO_muted' }, overview.push.enabled ? t.pushOn(overview.push.topic) : t.pushOff)))
      children.push(h('div', { key: 'relay', className: 'DUO_card' },
        h('h2', { className: 'DUO_cardTitle' }, t.relayTitle),
        h('p', { className: 'DUO_muted' }, overview.relayConnected ? t.relayOn(hostOf(overview.relay)) : t.relayOff(hostOf(overview.relay))),
        phones.length === 0 ? null : h('div', { className: 'DUO_row' },
          h('button', { type: 'button', className: 'DUO_button ' + (armed ? 'DUO_dangerArmed' : 'DUO_danger'), onClick: unpair },
            armed ? t.unpairConfirm : t.unpair)),
        phones.length === 0 ? null : h('p', { className: 'DUO_muted' }, t.unpairHint)))
      return h('div', { className: 'DUO_page' }, h('div', { className: 'DUO_inner' }, children))
    }

    // ── Plugin ───────────────────────────────────────────────────────────────
    const inject = ['slots', 'locale', 'remote', 'layout']

    function apply(ctx) {
      ctx.effect(() => ctx.locale.register(NS, { en, zh }), 'duo-remote: dictionaries')
      const t = ctx.locale.bind(NS)
      const mount = ctx.remote.$mount(CONTRIBUTION)
      const call = async (method) => {
        await mount
        const result = await ctx.get('remote.duoRemote')[method]()
        if (!result.ok) throw new Error(result.error.message || result.error.code)
        return result.value
      }
      // Strings with arguments are functions, so the page reads the active dictionary whole.
      const dictionary = () => (t('intro') === zh.intro ? zh : en)
      const face = () => ({
        t: dictionary,
        lang: () => document.documentElement.lang || navigator.language,
        overview: () => call('overview'),
        pairingCode: () => call('pairingCode'),
        unpairAll: () => call('unpairAll'),
        back: () => {
          const layout = ctx.get('layout')
          if (layout && typeof layout.selectPanel === 'function') layout.selectPanel(null)
        },
      })
      ctx.slots.inject('sidebar.panellist', () => ctx.slots.register({
        name: 'sidebar.panellist',
        id: PANEL_ID,
        order: 2,
        label: () => t('nav'),
        locale: NS,
      }, PhoneIcon))
      ctx.slots.inject('main', () => ctx.slots.register({
        name: 'main',
        key: PANEL_ID,
        locale: NS,
        inject: face,
      }, Page))
    }

    const bundleModule = { exports: {} }
    Object.defineProperty(bundleModule.exports, Symbol.toStringTag, { value: 'Module' })
    bundleModule.exports.apply = apply
    bundleModule.exports.inject = inject
    return bundleModule.exports
  },
})

/**
 * Joins the relay link to the dsh Host: answers phone requests, mirrors
 * Session state as events, holds DeepSeek's questions for the phone, and
 * raises notifications when turns finish.
 */

import { randomUUID } from 'node:crypto'
import { open as openFile, readdir, stat } from 'node:fs/promises'
import { homedir, hostname } from 'node:os'
import { basename, dirname, isAbsolute, join, resolve } from 'node:path'
import { Sealer, relayAuth } from './crypto.ts'
import { Directory, type QuestionView, type SessionView } from './directory.ts'
import type { AskUserQuestionAnswer, AskUserQuestionRequestEvent, HostContext } from './host.ts'
import { loadPairing, pairingLink, pairingPath, pairingSvg, rotatePairing, savePairing, type Pairing } from './pairing.ts'
import { Phones } from './phones.ts'
import { RelayLink } from './relay.ts'
import { ApnsSender, DeviceTokens, http2Transport, loadApns, type ApnsTransport, type PushMessage } from './push.ts'
import { Remote, RemoteFailure, failureOf } from './remote.ts'
import { LiveReducer, Transcript, type Item, type WireEvent } from './transcript.ts'

export const VERSION = '0.1.0'

/** Largest file `fs.read` hands over: sealed and encoded twice, it must still fit one 4 MB relay frame. */
const MAX_READ_BYTES = 2 * 1024 * 1024
/** Most entries `fs.read` lists for a folder. */
const MAX_FOLDER_ENTRIES = 1000

export interface BridgeConfig {
  readonly relay: string
  readonly home: string
  readonly hostName: string
  /** Hold DeepSeek questions for the phone even when no Web client answers. */
  readonly holdQuestions: boolean
  readonly historyMessages: number
  /** APNs delivery; tests substitute a fake. Defaults to HTTP/2 straight to Apple. */
  readonly apnsTransport?: ApnsTransport
}

interface Log {
  info(message: string): void
  warn(message: string): void
}

type Json = Record<string, unknown>

function obj(value: unknown): Json | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? value as Json : undefined
}

function str(value: unknown, name: string): string {
  if (typeof value !== 'string' || value === '') throw new RemoteFailure('duo/bad-request', `${name} is required`)
  return value
}

/** One open `session/follow` stream shared by every device viewing that Session. */
class Follow {
  readonly transcript = new Transcript()
  readonly live = new LiveReducer()
  readonly devices = new Set<string>()
  readonly controller = new AbortController()
  hasMore = false
  /** Oldest log position held, the `beforeSeq` of the next older page. */
  baseSeq: number | undefined
  /** Newest log position seen, the `throughSeq` cut that older pages are read against. */
  cursor = -1
  /** The older page being read, shared by devices scrolling up at the same time. */
  older: Promise<Json> | undefined
  ready: Promise<void>
  idleTimer: ReturnType<typeof setTimeout> | undefined
  liveTimer: ReturnType<typeof setTimeout> | undefined
  private markReady!: () => void
  private markFailed!: (error: unknown) => void

  constructor() {
    this.ready = this.reset()
  }

  reset(): Promise<void> {
    this.ready = new Promise<void>((resolve, reject) => {
      this.markReady = resolve
      this.markFailed = reject
    })
    this.ready.catch(() => undefined)
    return this.ready
  }

  resolve(): void { this.markReady() }
  reject(error: unknown): void { this.markFailed(error) }
}

interface HeldQuestion {
  readonly sessionId: string
  readonly callId: string
  readonly view: QuestionView
  readonly resolve: (answer: AskUserQuestionAnswer) => void
}

export class Bridge {
  private readonly ctx: HostContext
  private readonly config: BridgeConfig
  private readonly log: Log
  private readonly abort = new AbortController()
  private readonly remote: Remote
  private readonly directory: Directory
  private readonly follows = new Map<string, Follow>()
  private readonly opened = new Map<string, Set<string>>()
  private readonly held = new Map<string, HeldQuestion>()
  private readonly announced = new Set<string>()
  private readonly finishing = new Set<string>()
  private pairing!: Pairing
  private sealer!: Sealer
  private link: RelayLink | undefined
  private readonly disposers: (() => unknown)[] = []
  private tokens!: DeviceTokens
  private phones!: Phones
  private apns: ApnsSender | undefined
  private transport: ApnsTransport | undefined

  constructor(ctx: HostContext, config: BridgeConfig, log: Log) {
    this.ctx = ctx
    this.config = config
    this.log = log
    this.remote = new Remote(ctx)
    this.directory = new Directory(this.remote, {
      upsert: session => this.broadcast({ ev: 'sessions.upsert', session }),
      remove: sessionId => this.broadcast({ ev: 'sessions.remove', sessionId }),
      workspaces: workspaces => this.broadcast({ ev: 'workspaces.changed', workspaces }),
      questions: (sessionId, questions) => this.onQuestions(sessionId, questions),
    }, this.abort.signal, message => this.log.warn(message))
  }

  get pairingFile(): string {
    return pairingPath(this.config.home)
  }

  /** Written by `ios/scripts/install.sh` when it signs the app: this Mac's own Apple push key. */
  get apnsFile(): string {
    return join(dirname(this.pairingFile), 'apns.json')
  }

  async start(): Promise<void> {
    this.pairing = await loadPairing(this.pairingFile, this.config.relay)
    this.sealer = new Sealer(Buffer.from(this.pairing.secret, 'base64url'))
    this.tokens = new DeviceTokens(join(dirname(this.pairingFile), 'devices.json'))
    await this.tokens.load()
    this.phones = new Phones(join(dirname(this.pairingFile), 'phones.json'))
    await this.phones.load()
    this.transport = this.config.apnsTransport ?? http2Transport()
    try {
      this.apns = await loadApns(this.apnsFile, this.transport)
    } catch (error) {
      this.log.warn(`duo: push disabled, ${this.apnsFile} is unreadable: ${String(error)}`)
    }
    if (this.apns !== undefined) this.log.info(`duo: push notifications on (${this.apns.topic})`)
    this.listen()
    this.connect()
    void this.directory.ready().catch((error: unknown) => this.log.warn(`duo: session list unavailable: ${String(error)}`))
  }

  /** (Re)join the relay room named by the current pairing. */
  private connect(): void {
    this.link?.stop()
    this.sealer = new Sealer(Buffer.from(this.pairing.secret, 'base64url'))
    const link = new RelayLink({
      relay: this.pairing.relay,
      roomId: this.pairing.roomId,
      auth: relayAuth(Buffer.from(this.pairing.secret, 'base64url')),
      onMessage: (from, sealed) => { if (this.link === link) void this.receive(from, sealed) },
      onDevice: (id, online) => { if (this.link === link) this.onDevice(id, online) },
      log: this.log,
    })
    this.link = link
    link.start()
  }

  /**
   * Replace the room secret: every phone loses access at once and must scan the
   * new code. Their push tokens and records go with it.
   */
  async unpairAll(): Promise<void> {
    for (const follow of this.follows.values()) follow.controller.abort()
    this.follows.clear()
    this.opened.clear()
    this.pairing = await rotatePairing(this.pairingFile, this.config.relay)
    await this.tokens.clear()
    this.phones.clear()
    this.connect()
    this.log.info('duo: pairing reset; every phone was unpaired')
  }

  /** The pairing link and its QR code as SVG, for the iPhone page. */
  async pairingCode(): Promise<{ link: string; svg: string }> {
    const link = pairingLink(this.pairing, this.config.hostName)
    return { link, svg: await pairingSvg(link) }
  }

  /** Everything the iPhone page shows. */
  overview() {
    const online = this.link?.devices ?? new Set<string>()
    const pushed = new Set(this.tokens.entries().map(([id]) => id))
    return {
      hostName: this.config.hostName,
      relay: this.pairing.relay,
      relayConnected: this.link?.connected === true,
      push: this.apns === undefined
        ? { enabled: false as const, file: this.apnsFile }
        : { enabled: true as const, topic: this.apns.topic },
      phones: this.phones.entries()
        .map(([id, record]) => ({
          id,
          name: record.name ?? 'iPhone',
          model: record.model ?? 'iPhone',
          online: online.has(id),
          lastSeen: record.lastSeen,
          firstSeen: record.firstSeen,
          notifications: pushed.has(id),
        }))
        .sort((a, b) => Number(b.online) - Number(a.online) || b.lastSeen - a.lastSeen),
    }
  }

  async stop(): Promise<void> {
    this.abort.abort()
    for (const dispose of this.disposers.splice(0)) {
      try { dispose() } catch { /* unloading */ }
    }
    for (const follow of this.follows.values()) follow.controller.abort()
    this.follows.clear()
    this.link?.stop()
    if (this.config.apnsTransport === undefined) (this.transport as { close?: () => void } | undefined)?.close?.()
    await this.remote.dispose().catch(() => undefined)
  }

  status(): string {
    const devices = this.link?.devices.size ?? 0
    return [
      `Relay: ${this.pairing.relay} (${this.link?.connected === true ? 'connected' : 'offline'})`,
      `Phones online: ${devices}`,
      `Paired before: ${this.pairing.paired === true ? 'yes' : 'no'}`,
      `Notifications when the app is closed: ${this.apns === undefined ? 'off (sign the app with ios/scripts/install.sh --apns-key)' : `on (${this.apns.topic})`}`,
      `Pairing file: ${this.pairingFile}`,
    ].join('\n')
  }

  // ── Host events ────────────────────────────────────────────────────────

  private listen(): void {
    const on = (event: string, listener: (...args: never[]) => unknown, options?: { prepend?: boolean }): void => {
      this.disposers.push(this.ctx.on(event, listener, options))
    }
    on('api-session/added', (summary: Json) => this.directory.upsertSummary(summary))
    on('api-session/removed', (sessionId: string) => this.directory.removed(sessionId))
    on('api-session/activity', (sessionId: string, updatedAt: number) => this.directory.activity(sessionId, updatedAt))
    on('api-session/status', (sessionId: string, running: boolean) => {
      if (this.directory.status(sessionId, running)) void this.turnFinished(sessionId)
    })
    on('api-session/error', (sessionId: string, message: string) => {
      const follow = this.follows.get(sessionId)
      if (follow === undefined) return
      const item: Item = { id: `e${Date.now()}`, kind: 'notice', text: message, time: Date.now(), level: 'error' }
      follow.transcript.add(item)
      this.toFollowers(follow, { ev: 'session.items', sessionId, items: [item] })
    })
    // Prepend so the phone sees the question even while a Web client is also open.
    on('user-questions/request', ((request: AskUserQuestionRequestEvent, next: () => Promise<AskUserQuestionAnswer>) =>
      this.onQuestionRequest(request, next)) as never, { prepend: true })
  }

  private async onQuestionRequest(
    request: AskUserQuestionRequestEvent,
    next: () => Promise<AskUserQuestionAnswer>,
  ): Promise<AskUserQuestionAnswer> {
    const agent = request.agent
    if (agent === undefined || request.questions.length === 0) return await next()
    const sessionId = String(agent.session.id)
    const callId = request.wait?.callId ?? `q-${randomUUID()}`
    const holding = this.config.holdQuestions && this.pairing.paired === true

    let settle!: (answer: AskUserQuestionAnswer) => void
    const fromPhone = new Promise<AskUserQuestionAnswer>((resolve) => { settle = resolve })
    const view = toQuestionView(callId, request)
    this.held.set(callId, { sessionId, callId, view, resolve: settle })
    this.announce(sessionId, callId, view)

    const aborted = new Promise<never>((_, reject) => {
      const signal = request.signal
      if (signal === undefined) return
      if (signal.aborted) reject(signal.reason)
      signal.addEventListener('abort', () => reject(signal.reason), { once: true })
    })
    aborted.catch(() => undefined)

    const fromWeb = next().then(
      answer => ({ ok: true as const, answer }),
      (error: unknown) => ({ ok: false as const, error }),
    )
    try {
      const first = await Promise.race([fromWeb, fromPhone.then(answer => ({ ok: true as const, answer })), aborted])
      if (first.ok) return first.answer
      if (!holding) throw first.error
      // No Web client accepted it; wait for the phone (or the asker's own deadline).
      return await Promise.race([fromPhone, aborted])
    } finally {
      this.held.delete(callId)
      this.broadcast({ ev: 'question.resolved', sessionId, callId })
    }
  }

  private onQuestions(sessionId: string, questions: QuestionView[]): void {
    for (const question of questions) this.announce(sessionId, question.callId, question)
  }

  private announce(sessionId: string, callId: string, question: QuestionView): void {
    if (this.announced.has(callId)) return
    this.announced.add(callId)
    if (this.announced.size > 2000) this.announced.delete(this.announced.values().next().value!)
    const title = this.directory.title(sessionId)
    this.broadcast({ ev: 'question', sessionId, callId, title, questions: question.questions, state: question.state })
    const first = question.questions[0]
    this.push({
      kind: 'question',
      sessionId,
      callId,
      title,
      body: first === undefined ? 'DeepSeek has a question' : clip(first.question, 240),
      options: first?.options.slice(0, 4).map(option => clip(option.label, 40)) ?? [],
      questionId: first?.id,
      multi: (question.questions.length > 1) || first?.multiSelect === true,
    }, { category: 'QUESTION', thread: sessionId, collapse: callId.slice(0, 64) })
  }

  private async turnFinished(sessionId: string): Promise<void> {
    if (this.finishing.has(sessionId)) return
    this.finishing.add(sessionId)
    try {
      const transcript = await this.transcriptFor(sessionId)
      const items = transcript.ordered()
      const last = items.findLast(item => item.kind === 'turn')
      const reason = last?.kind === 'turn' ? last.reason : 'completed'
      const reply = transcript.lastReply()
      const title = this.directory.title(sessionId)
      const body = reason === 'cancelled' ? 'Stopped'
        : reason === 'error' ? 'The turn ended with an error'
          : reply === undefined ? 'Finished' : clip(reply.replace(/\s+/g, ' ').trim(), 280)
      this.broadcast({ ev: 'turn.finished', sessionId, title, summary: body, reason })
      this.push({ kind: 'turn', sessionId, title, body }, { category: 'TURN', thread: sessionId, collapse: `turn-${sessionId}`.slice(0, 64) })
    } catch (error) {
      this.log.warn(`duo: could not summarize finished turn: ${String(error)}`)
    } finally {
      this.finishing.delete(sessionId)
    }
  }

  /** The followed transcript, or a short one-off snapshot when nobody is viewing the Session. */
  private async transcriptFor(sessionId: string): Promise<Transcript> {
    const follow = this.follows.get(sessionId)
    if (follow !== undefined) {
      await follow.ready
      return follow.transcript
    }
    const transcript = new Transcript()
    const controller = new AbortController()
    try {
      const stream = await this.remote.stream<Json>('session/follow', controller.signal, {
        address: { kind: 'session', sessionId }, maxMessages: 6,
      })
      for await (const frame of stream) {
        if (frame.type === 'snapshot') {
          for (const record of Array.isArray(frame.records) ? frame.records : []) {
            const event = obj(obj(record)?.event)
            if (event !== undefined) transcript.apply(event as unknown as WireEvent)
          }
          break
        }
      }
    } finally {
      controller.abort()
    }
    return transcript
  }

  // ── Devices ────────────────────────────────────────────────────────────

  private onDevice(id: string, online: boolean): void {
    this.phones.seen(id)
    if (online) {
      if (this.pairing.paired !== true) {
        this.pairing = { ...this.pairing, paired: true }
        void savePairing(this.pairingFile, this.pairing)
        this.log.info('duo: first phone paired')
      }
      return
    }
    for (const sessionId of this.opened.get(id) ?? []) this.release(sessionId, id)
    this.opened.delete(id)
  }

  private send(to: string, message: object): void {
    this.link?.send(this.sealer.seal(message), to)
  }

  private broadcast(message: object): void {
    if (this.link === undefined || this.link.devices.size === 0) return
    this.link.send(this.sealer.seal(message))
  }

  private toFollowers(follow: Follow, message: object): void {
    if (follow.devices.size === 0) return
    const sealed = this.sealer.seal(message)
    for (const device of follow.devices) this.link?.send(sealed, device)
  }

  /** Push to every registered phone that is not connected right now (a connected one got the live event). */
  private push(payload: Json, meta: Omit<PushMessage, 'sealed'>): void {
    const apns = this.apns
    if (apns === undefined) return
    const message: PushMessage = { sealed: this.sealer.seal(payload), ...meta }
    for (const [deviceId, token] of this.tokens.entries()) {
      if (this.link?.devices.has(deviceId) === true) continue
      apns.send(token, message).then(
        async (result) => {
          if (result === 'dead') await this.tokens.remove(deviceId)
          else await this.tokens.save()
        },
        (error: unknown) => this.log.warn(`duo: push to ${deviceId} failed: ${String(error)}`),
      )
    }
  }

  private async receive(from: string, sealed: string): Promise<void> {
    const message = obj(this.sealer.open(sealed))
    if (message === undefined) {
      this.log.warn('duo: dropped a message that failed authentication')
      return
    }
    const id = message.id
    const op = message.op
    if (typeof op !== 'string') return
    try {
      const value = await this.handle(from, op, message)
      if (typeof id === 'number') this.send(from, { re: id, ok: true, value: value ?? null })
    } catch (error) {
      const failure = failureOf(error)
      if (!(error instanceof RemoteFailure)) this.log.warn(`duo: ${op} failed: ${failure.message}`)
      if (typeof id === 'number') this.send(from, { re: id, ok: false, error: { code: failure.code, message: failure.message } })
    }
  }

  private async handle(device: string, op: string, m: Json): Promise<unknown> {
    switch (op) {
      case 'hello': {
        const details = obj(m.device)
        this.phones.seen(device, {
          ...typeof details?.name === 'string' ? { name: details.name } : {},
          ...typeof details?.model === 'string' ? { model: details.model } : {},
        })
        await this.directory.ready()
        const [presets] = await Promise.all([this.presets()])
        return {
          host: this.config.hostName || hostname(),
          version: VERSION,
          presets,
          sessions: this.directory.sessions(),
          workspaces: this.directory.workspaces(),
          push: { enabled: this.apns !== undefined, ...this.apns === undefined ? {} : { topic: this.apns.topic } },
        }
      }
      case 'sessions.list':
        await this.directory.ready()
        return this.directory.sessions()
      case 'workspaces.list':
        await this.directory.ready()
        return this.directory.workspaces()
      case 'workspaces.add': {
        const value = await this.remote.call<{ workspace: Json }>('workspace/create', { path: str(m.path, 'path') })
        const workspace = value.workspace
        return {
          id: workspace.workspaceId,
          title: workspace.title,
          path: workspace.path,
          sessionIds: workspace.sessionIds ?? [],
        }
      }
      case 'fs.list': {
        const listing = await this.listDirectories(typeof m.path === 'string' ? m.path : undefined)
        const crumbs = Array.isArray(listing.crumbs) ? listing.crumbs as Json[] : []
        const entries = Array.isArray(listing.entries) ? listing.entries as Json[]
          : Array.isArray(listing.children) ? listing.children as Json[] : []
        return {
          path: listing.path,
          home: listing.home,
          parent: crumbs.length > 1 ? crumbs[crumbs.length - 2]!.path : undefined,
          entries: entries.map(entry => ({ name: entry.name, path: entry.path, hidden: entry.hidden === true })),
        }
      }
      case 'fs.read':
        return await this.readFile(str(m.path, 'path'), typeof m.sessionId === 'string' ? m.sessionId : undefined)
      case 'session.create': {
        const request: Json = {}
        if (typeof m.workspaceId === 'string') request.workspaceId = m.workspaceId
        else if (typeof m.cwd === 'string') request.cwd = m.cwd
        if (typeof m.preset === 'string') request.agentPreset = m.preset
        const created = await this.remote.call<{ sessionId: string; agentPreset?: string }>('session/create', request)
        await this.directory.refresh().catch(() => undefined)
        return this.directory.view(created.sessionId) ?? {
          id: created.sessionId, title: 'New session', updatedAt: Date.now(), running: false, blank: true,
          questions: 0, ...created.agentPreset === undefined ? {} : { preset: created.agentPreset },
        } satisfies SessionView
      }
      case 'session.open':
        return await this.open(device, str(m.sessionId, 'sessionId'))
      case 'session.older':
        return await this.older(str(m.sessionId, 'sessionId'))
      case 'session.close':
        this.release(str(m.sessionId, 'sessionId'), device)
        this.opened.get(device)?.delete(m.sessionId as string)
        return null
      case 'session.prompt':
        return await this.prompt(str(m.sessionId, 'sessionId'), str(m.text, 'text'),
          m.mode === 'steer' ? 'steer' : 'queue', typeof m.timeZone === 'string' ? m.timeZone : undefined)
      case 'session.cancel':
        await this.remote.call('session/cancel', { sessionId: str(m.sessionId, 'sessionId') })
        return null
      case 'session.model': {
        const request: Json = {
          sessionId: str(m.sessionId, 'sessionId'),
          provider: str(m.provider, 'provider'),
          model: str(m.model, 'model'),
        }
        if (typeof m.effort === 'string') request.reasoningEffort = m.effort
        const value = await this.remote.call<{ selected: Json }>('session/selectModel', request)
        return {
          provider: value.selected.provider,
          model: value.selected.model,
          ...typeof value.selected.reasoningEffort === 'string' ? { effort: value.selected.reasoningEffort } : {},
        }
      }
      case 'session.preset': {
        const preset = await this.remote.call<string>('agentPresets/select', str(m.sessionId, 'sessionId'), str(m.preset, 'preset'))
        return { preset }
      }
      case 'session.rename':
        await this.remote.call('session/rename', { sessionId: str(m.sessionId, 'sessionId'), title: str(m.title, 'title') })
        return null
      case 'models.catalog':
        return await this.catalog()
      case 'presets.list':
        return await this.presets()
      case 'commands.list':
        return await this.commands(str(m.sessionId, 'sessionId'))
      case 'question.answer':
        return await this.answer(str(m.sessionId, 'sessionId'), str(m.callId, 'callId'), m.answers)
      case 'push.register': {
        const token = str(m.token, 'token').toLowerCase()
        if (!/^[0-9a-f]{32,200}$/.test(token)) throw new RemoteFailure('duo/bad-request', 'token must be hex')
        await this.tokens.set(device, token, m.env === 'production' ? 'production' : 'sandbox')
        if (typeof m.topic === 'string' && this.apns !== undefined && m.topic !== this.apns.topic) {
          this.log.warn(`duo: phone app ${m.topic} differs from the APNs topic ${this.apns.topic}; pushes will be refused`)
        }
        return { enabled: this.apns !== undefined }
      }
      case 'push.unregister':
        await this.tokens.remove(device)
        return null
      case 'pairing.status':
        return { relay: this.pairing.relay, devices: [...this.link?.devices ?? []] }
      default:
        throw new RemoteFailure('duo/unknown-op', `unknown operation ${op}`)
    }
  }

  /**
   * One file DeepSeek linked to, for the phone to preview. A relative path is read against the
   * Session's folder, the way the agent wrote it. The paired phone is the Host's owner, as it is
   * for `fs.list`, so any file this user can read is fair game.
   */
  private async readFile(path: string, sessionId: string | undefined) {
    const home = path === '~' || path.startsWith('~/') ? join(homedir(), path.slice(1)) : path
    const cwd = sessionId === undefined ? undefined : this.directory.view(sessionId)?.cwd
    const full = isAbsolute(home) ? home : resolve(cwd ?? homedir(), home)
    const handle = await openFile(full, 'r').catch((error: NodeJS.ErrnoException) => {
      throw new RemoteFailure(error.code === 'ENOENT' ? 'duo/not-found' : 'duo/unreadable',
        error.code === 'ENOENT' ? `${full} does not exist` : `${full} can't be read (${error.code ?? error.message})`)
    })
    try {
      const stat = await handle.stat()
      if (stat.isDirectory()) return await this.listFolder(full)
      if (stat.size > MAX_READ_BYTES) {
        throw new RemoteFailure('duo/too-large', `${basename(full)} is ${(stat.size / 1048576).toFixed(1)} MB, over the 2 MB preview limit`)
      }
      const data = await handle.readFile()
      return { path: full, name: basename(full), size: data.length, data: data.toString('base64') }
    } finally {
      await handle.close()
    }
  }

  /**
   * One level of folders for the phone's folder browser. The desktop app composes the native chooser
   * behind `directoryPicker`, which refuses `list` with `directory-picker/unavailable`; the plugin runs
   * on the Host, so it then lists the folder itself in the browse backend's shape.
   */
  private async listDirectories(path: string | undefined): Promise<Json> {
    try {
      return await this.remote.call<Json>('directoryPicker/list', path)
    } catch (error) {
      if (!(error instanceof RemoteFailure) || error.code !== 'directory-picker/unavailable') throw error
    }
    const home = homedir()
    if (path !== undefined && !isAbsolute(path)) throw new RemoteFailure('directory-picker/unreadable', `cannot list "${path}": not an absolute path`)
    const target = resolve(path ?? home)
    const dirents = await readdir(target, { withFileTypes: true }).catch((error: NodeJS.ErrnoException) => {
      throw new RemoteFailure('directory-picker/unreadable', `cannot list ${target}: ${error.code ?? error.message}`)
    })
    const entries: Json[] = []
    for (const dirent of dirents.sort((a, b) => a.name.localeCompare(b.name))) {
      const full = join(target, dirent.name)
      const folder = dirent.isDirectory() || dirent.isSymbolicLink() && await stat(full).then(s => s.isDirectory(), () => false)
      if (folder) entries.push({ name: dirent.name, path: full, hidden: dirent.name.startsWith('.') })
      if (entries.length === MAX_FOLDER_ENTRIES) break
    }
    const crumbs: Json[] = []
    for (let current = target; ; current = dirname(current)) {
      crumbs.unshift({ name: basename(current) || current, path: current })
      if (dirname(current) === current) break
    }
    return { path: target, home, crumbs, entries }
  }

  /** A linked folder's files and subfolders, folders first, for the phone to pick one to preview. */
  private async listFolder(path: string) {
    const entries = await readdir(path, { withFileTypes: true })
    const shown = entries
      .filter(entry => entry.isFile() || entry.isDirectory())
      .sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name, undefined, { numeric: true }))
      .slice(0, MAX_FOLDER_ENTRIES)
    return {
      path,
      name: basename(path),
      folder: true,
      entries: shown.map(entry => ({
        name: entry.name,
        path: join(path, entry.name),
        folder: entry.isDirectory(),
        hidden: entry.name.startsWith('.'),
      })),
      truncated: entries.length > shown.length,
    }
  }

  private async prompt(sessionId: string, text: string, mode: 'queue' | 'steer', timeZone: string | undefined) {
    const line = text.trim()
    if (line.startsWith('/')) {
      const execution = await this.remote.call<{ result?: { kind: string; text?: string } } | undefined>(
        'commands/execute', sessionId, line, [])
      if (execution !== undefined && execution !== null) {
        if (execution.result?.kind === 'error') {
          throw new RemoteFailure('duo/command-failed', execution.result.text ?? 'Command failed')
        }
        return { kind: 'command', text: execution.result?.text }
      }
    }
    await this.remote.call('session/prompt', {
      requestId: randomUUID(),
      sessionId,
      mode,
      content: [{ type: 'text', text }],
      ...timeZone === undefined ? {} : { clientTimeZone: timeZone },
    })
    return { kind: 'prompt' }
  }

  private async answer(sessionId: string, callId: string, raw: unknown) {
    const answers = (Array.isArray(raw) ? raw : []).flatMap((item) => {
      const row = obj(item)
      if (typeof row?.id !== 'string') return []
      const selected = Array.isArray(row.selected) ? row.selected.filter(label => typeof label === 'string') : []
      return [{ id: row.id, selected, ...typeof row.custom === 'string' && row.custom !== '' ? { custom: row.custom } : {} }]
    })
    const held = this.held.get(callId)
    if (held !== undefined) {
      held.resolve({ answers })
      return { accepted: true }
    }
    const accepted = await this.remote.call<boolean>('userQuestions/answer', sessionId, callId, { answers })
    if (!accepted) throw new RemoteFailure('duo/question-closed', 'This question was already answered')
    this.broadcast({ ev: 'question.resolved', sessionId, callId })
    return { accepted: true }
  }

  private async catalog() {
    const catalog = await this.remote.call<Json>('session/modelCatalog')
    const groups = Array.isArray(catalog.groups) ? catalog.groups as Json[] : []
    return {
      default: catalog.default,
      groups: groups.map(group => ({
        id: group.id,
        name: group.name,
        models: (Array.isArray(group.models) ? group.models as Json[] : []).map((model) => {
          const reasoning = obj(model.reasoning)
          return {
            id: model.id,
            name: model.name,
            ...typeof model.description === 'string' ? { description: model.description } : {},
            efforts: Array.isArray(reasoning?.efforts)
              ? (reasoning.efforts as Json[]).map(effort => ({ id: effort.id, name: effort.name }))
              : [],
            ...typeof reasoning?.defaultEffort === 'string' ? { defaultEffort: reasoning.defaultEffort } : {},
          }
        }),
      })),
    }
  }

  private async presets() {
    try {
      const roster = await this.remote.call<{ presets: Json[] }>('agentPresets/list')
      return roster.presets
        .filter(preset => preset.broken === undefined)
        .map(preset => ({
          id: preset.id,
          name: typeof preset.name === 'string' ? preset.name : preset.id,
          ...typeof preset.description === 'string' ? { description: preset.description } : {},
          isDefault: preset.isDefault === true,
        }))
    } catch {
      return []
    }
  }

  private async commands(sessionId: string) {
    const [commands, skills] = await Promise.all([
      this.remote.call<Json[]>('commands/list', sessionId).catch(() => []),
      this.remote.call<{ skills: Json[] }>('skills/list', { sessionId }).catch(() => ({ skills: [] })),
    ])
    const rows = new Map<string, Json>()
    for (const skill of skills.skills) {
      if (typeof skill.name !== 'string') continue
      rows.set(skill.name, { name: skill.name, description: skill.description ?? '', kind: 'skill' })
    }
    for (const command of commands) {
      if (typeof command.name !== 'string') continue
      const input = obj(command.input)
      rows.set(command.name, {
        name: command.name,
        description: command.description ?? '',
        kind: 'command',
        ...typeof input?.hint === 'string' ? { hint: input.hint } : {},
      })
    }
    return [...rows.values()].sort((a, b) => String(a.name).localeCompare(String(b.name)))
  }

  // ── Session follow streams ─────────────────────────────────────────────

  private async open(device: string, sessionId: string) {
    let set = this.opened.get(device)
    if (set === undefined) this.opened.set(device, set = new Set())
    set.add(sessionId)
    let follow = this.follows.get(sessionId)
    if (follow === undefined) {
      follow = new Follow()
      this.follows.set(sessionId, follow)
      void this.run(sessionId, follow)
    }
    clearTimeout(follow.idleTimer)
    follow.devices.add(device)
    await follow.ready
    const live = follow.live.attempt
    // Re-send questions still waiting in this Session so a fresh screen can answer them.
    const waiting = new Map<string, QuestionView>()
    for (const held of this.held.values()) if (held.sessionId === sessionId) waiting.set(held.callId, held.view)
    for (const question of this.directory.pendingQuestions(sessionId)) waiting.set(question.callId, question)
    for (const question of waiting.values()) {
      this.send(device, {
        ev: 'question', sessionId, callId: question.callId, title: this.directory.title(sessionId),
        questions: question.questions, state: question.state,
      })
    }
    return {
      session: this.directory.view(sessionId),
      items: follow.transcript.ordered(),
      hasMore: follow.hasMore,
      live: live === undefined ? null : { ...live, tools: live.tools.map(tool => ({ ...tool })) },
    }
  }

  /**
   * Read the page of history before what the Session's follow holds, the way the desktop app does
   * as its chat scrolls up: at least 50 messages and two Turn starts, capped at 500.
   */
  private older(sessionId: string): Promise<Json> {
    const follow = this.follows.get(sessionId)
    if (follow === undefined) throw new RemoteFailure('duo/not-open', 'Open the session first')
    follow.older ??= (async () => {
      if (!follow.hasMore || follow.baseSeq === undefined) return { items: [], hasMore: false }
      const page = await this.remote.call<{ records?: unknown[]; hasMore?: boolean }>('session/page', {
        address: { kind: 'session', sessionId },
        throughSeq: follow.cursor,
        beforeSeq: follow.baseSeq,
        maxMessages: 500,
        turnWindow: { minMessages: 50, minTurns: 2 },
      })
      const changed = new Set<string>()
      for (const record of page.records ?? []) {
        const event = obj(obj(record)?.event)
        if (event === undefined) continue
        if (typeof event.seq === 'number') follow.baseSeq = Math.min(follow.baseSeq ?? event.seq, event.seq)
        for (const item of follow.transcript.apply(event as unknown as WireEvent)) changed.add(item.id)
      }
      follow.hasMore = page.hasMore === true
      return { items: follow.transcript.ordered().filter(item => changed.has(item.id)), hasMore: follow.hasMore }
    })().finally(() => { follow.older = undefined })
    return follow.older
  }

  private release(sessionId: string, device: string): void {
    const follow = this.follows.get(sessionId)
    if (follow === undefined) return
    follow.devices.delete(device)
    if (follow.devices.size > 0) return
    clearTimeout(follow.idleTimer)
    follow.idleTimer = setTimeout(() => {
      if (follow.devices.size > 0) return
      follow.controller.abort()
      this.follows.delete(sessionId)
    }, 60_000)
    follow.idleTimer.unref?.()
  }

  /** Run one follow stream, reconnecting with a fresh snapshot after failures. */
  private async run(sessionId: string, follow: Follow): Promise<void> {
    let attempt = 0
    let first = true
    while (!follow.controller.signal.aborted && !this.abort.signal.aborted) {
      const signal = AbortSignal.any([follow.controller.signal, this.abort.signal])
      try {
        const stream = await this.remote.stream<Json>('session/follow', signal, {
          address: { kind: 'session', sessionId },
          assistantStream: true,
          maxMessages: this.config.historyMessages,
        })
        for await (const frame of stream) {
          attempt = 0
          this.onFollowFrame(sessionId, follow, frame, first)
          first = false
        }
      } catch (error) {
        if (signal.aborted) return
        if (first) {
          follow.reject(error)
          this.follows.delete(sessionId)
          return
        }
        this.log.warn(`duo: follow ${sessionId} interrupted: ${String((error as Error).message ?? error)}`)
      }
      await new Promise(resolve => setTimeout(resolve, Math.min(15_000, 500 * 2 ** attempt++)).unref?.())
    }
  }

  private onFollowFrame(sessionId: string, follow: Follow, frame: Json, first: boolean): void {
    switch (frame.type) {
      case 'snapshot': {
        follow.transcript.clear()
        follow.baseSeq = undefined
        follow.cursor = typeof frame.cursor === 'number' ? frame.cursor : -1
        for (const record of Array.isArray(frame.records) ? frame.records : []) {
          const event = obj(obj(record)?.event)
          if (event === undefined) continue
          if (typeof event.seq === 'number') {
            follow.baseSeq ??= event.seq
            follow.cursor = Math.max(follow.cursor, event.seq)
          }
          follow.transcript.apply(event as unknown as WireEvent)
        }
        follow.hasMore = frame.hasMore === true
        follow.live.end()
        const active = obj(obj(frame.assistantStream)?.activeAttempt)
        if (active !== undefined && typeof active.attemptId === 'string') {
          follow.live.start(active.attemptId)
          for (const record of Array.isArray(active.stream) ? active.stream : []) follow.live.chunk(record)
          follow.live.flush()
        }
        if (first) {
          follow.resolve()
        } else {
          this.toFollowers(follow, { ev: 'session.items', sessionId, items: follow.transcript.ordered(), replace: true, hasMore: follow.hasMore })
          this.toFollowers(follow, { ev: 'session.live', sessionId, live: follow.live.attempt ?? null })
        }
        return
      }
      case 'event': {
        const event = obj(frame.event)
        if (event === undefined) return
        if (typeof event.seq === 'number') follow.cursor = Math.max(follow.cursor, event.seq)
        const changed = follow.transcript.apply(event as unknown as WireEvent)
        if (changed.length > 0) this.toFollowers(follow, { ev: 'session.items', sessionId, items: changed })
        return
      }
      case 'assistant-stream': {
        const inner = obj(frame.frame)
        if (inner === undefined) return
        if (inner.type === 'start' && typeof inner.attemptId === 'string') {
          follow.live.start(inner.attemptId)
          this.scheduleLive(sessionId, follow)
        } else if (inner.type === 'chunk') {
          follow.live.chunk(inner.chunk)
          this.scheduleLive(sessionId, follow)
        } else if (inner.type === 'end') {
          follow.live.end()
          clearTimeout(follow.liveTimer)
          follow.liveTimer = undefined
          this.toFollowers(follow, { ev: 'session.live', sessionId, live: null })
        }
        return
      }
      default:
    }
  }

  /** Coalesce streaming deltas to ~12 frames per second. */
  private scheduleLive(sessionId: string, follow: Follow): void {
    if (follow.liveTimer !== undefined) return
    follow.liveTimer = setTimeout(() => {
      follow.liveTimer = undefined
      const delta = follow.live.flush()
      if (delta !== undefined) this.toFollowers(follow, { ev: 'session.live', sessionId, delta })
    }, 80)
  }
}

function clip(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`
}

function toQuestionView(callId: string, request: AskUserQuestionRequestEvent): QuestionView {
  return {
    callId,
    state: 'open',
    questions: request.questions.map(item => ({
      id: item.id,
      question: item.question,
      ...item.header === undefined ? {} : { header: item.header },
      ...item.detail === undefined ? {} : { detail: item.detail },
      options: (item.options ?? []).map(option => ({ label: option.label, ...option.description === undefined ? {} : { description: option.description } })),
      multiSelect: item.multiSelect === true,
      ...item.intent === undefined ? {} : { intent: item.intent.kind },
    })),
  }
}

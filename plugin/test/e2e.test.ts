/**
 * End to end: real relay process + this plugin on a fake dsh Host + a
 * simulated phone speaking the sealed protocol, exactly as the iOS app does.
 */

import { spawn, type ChildProcess } from 'node:child_process'
import { generateKeyPairSync } from 'node:crypto'
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, test } from 'node:test'
import assert from 'node:assert/strict'
import { Sealer, relayAuth } from '../src/crypto.ts'
import type { HostContext, InvokeRemoteRequest, PeerScope } from '../src/host.ts'
import { apply } from '../src/index.ts'
import { socketUrl } from '../src/relay.ts'

const port = 20_000 + Math.floor(Math.random() * 20_000)
/** Set DUO_RELAY to run against a deployed relay instead of a local one. */
const relay = process.env.DUO_RELAY ?? `http://127.0.0.1:${port}`
let server: ChildProcess | undefined
let home: string
const manifests: unknown[] = []
const services = new Map<string, unknown>()
const pushes: Array<{ env: string; token: string; headers: Record<string, string>; body: string }> = []

/** Async queue used to feed stream frames from the test. */
class Feed<T> implements AsyncIterable<T> {
  private readonly items: T[] = []
  private waiter: ((item: IteratorResult<T>) => void) | undefined
  private closed = false
  push(item: T): void {
    if (this.waiter !== undefined) {
      const waiter = this.waiter
      this.waiter = undefined
      waiter({ value: item, done: false })
    } else this.items.push(item)
  }
  close(): void {
    this.closed = true
    this.waiter?.({ value: undefined, done: true })
  }
  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: () => {
        const item = this.items.shift()
        if (item !== undefined) return Promise.resolve({ value: item, done: false })
        if (this.closed) return Promise.resolve({ value: undefined, done: true })
        return new Promise(resolve => { this.waiter = resolve })
      },
      return: () => {
        this.close()
        return Promise.resolve({ value: undefined, done: true })
      },
    }
  }
}

const calls: InvokeRemoteRequest[] = []
/** The Host activates its Session service after the plugin applies; the first list loses that race. */
let sessionListFailures = 1
const listeners = new Map<string, Array<(...args: never[]) => unknown>>()
const followFeed = new Feed<Record<string, unknown>>()
const commands: Array<{ name: string }> = []

const goal = {
  goal: { id: 'goal-1', revision: 1, objective: 'Ship the login fix with a regression test', phase: 'active', maxGoalRounds: 8 },
  roundsStarted: 2,
  createdAt: 100,
  updatedAt: 900,
}

const summary = {
  sessionId: 'sess-1', agentAvailable: true, updatedAt: 1000, running: false, blank: false, cwd: '/work/app',
  projections: { kind: 'sequenced', asOfSeq: 9, values: {
    title: 'Fix the login bug',
    agentPreset: 'standard',
    modelSelection: { next: { provider: 'deepseek', model: 'deepseek-v4', reasoningEffort: 'high' }, lastUsed: null },
    goal,
  } },
}

const subagentSummary = {
  sessionId: 'sess-sub', agentAvailable: true, updatedAt: 900, running: false, blank: false, cwd: '/work/app',
  parentSessionId: 'sess-1', origin: 'subagent',
  projections: { kind: 'sequenced', asOfSeq: 9, values: {
    title: 'Triage the login race',
    subagent: { mode: 'continuable', label: 'Login triage' },
  } },
}

const history = [
  { type: 'event', event: { type: 'turn/start', seq: 1, time: 100, data: { turn: 1 } } },
  { type: 'event', event: { type: 'user/message', seq: 2, time: 101, data: { id: 'm1', role: 'user', source: { kind: 'user', rpcId: 'r' }, content: [{ type: 'text', text: 'Why does login fail?' }] } } },
  { type: 'event', event: { type: 'assistant/message', seq: 3, time: 102, data: { turn: 1, step: 1, stream: [], message: { id: 'm2', role: 'assistant', content: [
    { type: 'reasoning', text: 'Look at auth.ts first.' },
    { type: 'text', text: 'Checking the auth module.' },
    { type: 'tool-call', id: 'call-1', name: 'read', arguments: '{"path":"auth.ts"}' },
  ] } } } },
  { type: 'event', event: { type: 'tool/result', seq: 4, time: 103, data: { turn: 1, step: 1, message: { id: 'm3', role: 'tool', toolCallId: 'call-1', content: [{ type: 'text', text: 'export function login() {}' }] } } } },
  { type: 'event', event: { type: 'turn/end', seq: 5, time: 104, data: { turn: 1, reason: { kind: 'completed' } } } },
]

const ctx: HostContext = {
  typertGateway: {
    async invoke(request) {
      calls.push(request)
      const endpoint = `${request.namespace}/${request.method}`
      switch (endpoint) {
        case 'session/list':
          if (sessionListFailures-- > 0) {
            throw Object.assign(
              new Error('typert gateway: session/list: active Service "sessionController" is unavailable'),
              { code: 'gateway/service-unavailable' },
            )
          }
          return { items: [summary, subagentSummary] }
        case 'agentPresets/list': return { presets: [
          { id: 'standard', name: 'Standard', isDefault: true }, { id: 'ptc', name: 'PTC' },
          { id: 'minimal', name: 'Minimal' }, { id: 'cordis', name: 'Creator' },
        ] }
        case 'session/modelCatalog': return {
          default: { provider: 'deepseek', model: 'deepseek-v4' }, routableProviders: ['deepseek'], failures: [],
          groups: [{ id: 'deepseek', name: 'DeepSeek', models: [{ id: 'deepseek-v4', name: 'DeepSeek V4',
            reasoning: { efforts: [{ id: 'low', name: 'Low' }, { id: 'high', name: 'High' }], defaultEffort: 'high' } }] }],
        }
        case 'session/selectModel': {
          const req = request.args.request as Record<string, string>
          return { selected: { provider: req.provider, model: req.model, reasoningEffort: req.reasoningEffort } }
        }
        case 'commands/list': return [{ name: 'compact', description: 'Summarize history' }]
        case 'skills/list': return { skills: [{ name: 'review', description: 'Review the diff', modelInvocable: true }] }
        case 'commands/execute':
          commands.push({ name: String(request.args.line) })
          return String(request.args.line).startsWith('/compact') ? { commandId: 'c1', result: { kind: 'success', text: 'Compacted' } } : undefined
        case 'session/prompt': return { accepted: true }
        case 'goals/get': {
          if (request.args.agentId !== 'sess-1') return undefined
          return { ...goal.goal, roundsStarted: goal.roundsStarted, createdAt: goal.createdAt, updatedAt: goal.updatedAt, activation: 'armed' }
        }
        case 'goals/pause': {
          if (request.args.agentId !== 'sess-1') throw Object.assign(new Error('unknown agent'), { code: 'goals/unknown' })
          return { ...goal.goal, phase: 'paused', revision: 2, roundsStarted: goal.roundsStarted, createdAt: goal.createdAt, updatedAt: Date.now(), activation: 'disarmed' }
        }
        case 'subagents/prompt': return { messageId: 'msg-1' }
        case 'agentPresets/select': return request.args.agentPreset
        default: throw Object.assign(new Error(`unexpected ${endpoint}`), { code: 'test/unexpected' })
      }
    },
    async stream(request) {
      calls.push(request)
      const endpoint = `${request.namespace}/${request.method}`
      if (endpoint === 'session/follow') {
        followFeed.push({ type: 'snapshot', header: {}, cursor: 5, records: history, hasMore: false, projections: { asOfSeq: 5, values: {} } })
        return followFeed
      }
      const feed = new Feed<unknown>()
      if (endpoint === 'session/control') feed.push({ type: 'baseline', value: { projections: {} } })
      if (endpoint === 'workspace/follow') {
        feed.push({ type: 'baseline', value: { items: [{ workspaceId: 'ws-1', path: '/work/app', title: 'app', sessionIds: ['sess-1'] }], archivedSessionIds: [], pinnedSessionIds: [] } })
      }
      request.signal?.addEventListener('abort', () => feed.close())
      return feed
    },
  },
  connection: {
    createPeer: (): PeerScope => ({ id: 'peer', signal: new AbortController().signal, dispose: async () => {} }),
  },
  logger: { info: () => {}, warn: () => {} },
  get: ((name: string) => {
    if (name === 'profileContext') return { home }
    if (name === 'typert') return { register: (manifest: unknown) => { manifests.push(manifest); return () => {} } }
    return undefined
  }) as HostContext['get'],
  provide(name: string, value: unknown) {
    services.set(name, value)
    return () => services.delete(name)
  },
  on(event, listener) {
    const list = listeners.get(event) ?? []
    list.push(listener)
    listeners.set(event, list)
    return () => {}
  },
}

function emit(event: string, ...args: unknown[]): unknown {
  return (listeners.get(event)?.[0] as ((...values: unknown[]) => unknown) | undefined)?.(...args)
}

before(async () => {
  home = await mkdtemp(join(tmpdir(), 'dsh-duo-home-'))
  if (process.env.DUO_RELAY === undefined) {
    const dataDir = await mkdtemp(join(tmpdir(), 'dsh-duo-relay-'))
    const child = spawn(process.execPath, [join(import.meta.dirname, '..', '..', 'relay', 'src', 'node.ts')], {
      env: { ...process.env, PORT: String(port), DATA_DIR: dataDir },
      stdio: ['ignore', 'pipe', 'inherit'],
    })
    server = child
    await new Promise<void>((resolve) => {
      child.stdout!.on('data', (chunk: Buffer) => { if (chunk.toString().includes('listening')) resolve() })
    })
  }
  const stdout = process.stdout.write.bind(process.stdout)
  process.stdout.write = ((chunk: string | Uint8Array) => typeof chunk === 'string' && chunk.includes('DSH Duo') ? true : stdout(chunk)) as typeof process.stdout.write
  // This Mac's own APNs key, as ios/scripts/install.sh writes it.
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
  await mkdir(join(home, 'duo-remote'), { recursive: true })
  await writeFile(join(home, 'duo-remote', 'AuthKey_TESTKEY001.p8'), privateKey.export({ type: 'pkcs8', format: 'pem' }))
  await writeFile(join(home, 'duo-remote', 'apns.json'), JSON.stringify({
    keyId: 'TESTKEY001', teamId: 'TEAMID0001', keyFile: 'AuthKey_TESTKEY001.p8', topic: 'ai.example.duo',
  }))
  apply(ctx, { relay, hostName: 'test-mac', apnsTransport: async (env, token, headers, body) => {
    pushes.push({ env, token, headers, body })
    // The phone's token was minted for production; sandbox rejects it the way Apple does.
    return env === 'sandbox' ? { status: 400, reason: 'BadDeviceToken' } : { status: 200 }
  } })
})

after(() => {
  // Unload the plugin so its relay link closes; a deployed relay would otherwise keep the process alive.
  emit('dispose')
  server?.kill()
})

class Phone {
  private nextId = 1
  private readonly waiting = new Map<number, (value: Record<string, unknown>) => void>()
  readonly events: Array<Record<string, unknown>> = []
  private eventWaiters: Array<{ ev: string; resolve: (value: Record<string, unknown>) => void }> = []
  readonly ws: WebSocket
  readonly sealer: Sealer
  constructor(ws: WebSocket, sealer: Sealer) {
    this.ws = ws
    this.sealer = sealer
    ws.addEventListener('message', (event) => {
      const frame = JSON.parse(String(event.data)) as { t: string; d?: string }
      if (frame.t !== 'msg' || frame.d === undefined) return
      const message = sealer.open(frame.d) as Record<string, unknown>
      if (typeof message.re === 'number') {
        this.waiting.get(message.re)?.(message)
        return
      }
      const index = this.eventWaiters.findIndex(waiter => waiter.ev === message.ev)
      if (index >= 0) this.eventWaiters.splice(index, 1)[0]!.resolve(message)
      else this.events.push(message)
    })
  }
  async call(op: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    const id = this.nextId++
    const reply = new Promise<Record<string, unknown>>(resolve => this.waiting.set(id, resolve))
    this.ws.send(JSON.stringify({ t: 'msg', d: this.sealer.seal({ id, op, ...params }) }))
    return await reply
  }
  event(ev: string): Promise<Record<string, unknown>> {
    const index = this.events.findIndex(message => message.ev === ev)
    if (index >= 0) return Promise.resolve(this.events.splice(index, 1)[0]!)
    return new Promise(resolve => this.eventWaiters.push({ ev, resolve }))
  }
}

async function connectPhone(): Promise<Phone> {
  const path = join(home, 'duo-remote', 'pairing.json')
  let pairing: { roomId: string; secret: string } | undefined
  for (let attempt = 0; attempt < 50 && pairing === undefined; attempt++) {
    try { pairing = JSON.parse(await readFile(path, 'utf8')) } catch { await new Promise(resolve => setTimeout(resolve, 100)) }
  }
  assert.ok(pairing, 'plugin wrote a pairing file')
  const secret = Buffer.from(pairing.secret, 'base64url')
  // Give the host a moment to register the room before the device joins.
  let ws: WebSocket | undefined
  for (let attempt = 0; attempt < 50 && ws === undefined; attempt++) {
    const candidate = new WebSocket(socketUrl(relay, pairing.roomId, { role: 'device', auth: relayAuth(secret), device: 'iphone-duo-1' }))
    const ok = await new Promise<boolean>((resolve) => {
      candidate.addEventListener('open', () => resolve(true))
      candidate.addEventListener('error', () => resolve(false))
    })
    if (ok) ws = candidate
    else await new Promise(resolve => setTimeout(resolve, 100))
  }
  assert.ok(ws, 'phone joined the room')
  return new Phone(ws, new Sealer(secret))
}

test('a paired phone drives the Host through the relay', async () => {
  const phone = await connectPhone()

  const hello = await phone.call('hello', { device: { name: 'Test', model: 'iPhone Duo' } })
  assert.equal(hello.ok, true)
  const value = hello.value as { host: string; presets: Array<{ id: string }>; sessions: Array<Record<string, unknown>>; workspaces: Array<Record<string, unknown>> }
  assert.equal(value.host, 'test-mac')
  assert.deepEqual(value.presets.map(preset => preset.id), ['standard', 'ptc', 'minimal', 'cordis'])
  assert.equal(value.sessions[0]!.title, 'Fix the login bug')
  assert.deepEqual(value.sessions[0]!.model, { provider: 'deepseek', model: 'deepseek-v4', effort: 'high' })
  assert.deepEqual(value.sessions[0]!.goal, {
    id: 'goal-1', revision: 1, objective: 'Ship the login fix with a regression test', phase: 'active',
    roundsStarted: 2, maxGoalRounds: 8,
  })
  const child = value.sessions.find(session => typeof session.parentId === 'string')
  assert.equal(child?.parentId, 'sess-1')
  assert.deepEqual(child?.subagent, { mode: 'continuable', label: 'Login triage' })

  // The first list lost the activation race; the plugin retried it instead of caching the error.
  assert.equal(calls.filter(call => call.namespace === 'session' && call.method === 'list').length, 2)

  // Session list request used the fallback wire name.
  assert.deepEqual(calls.find(call => call.method === 'list' && call.namespace === 'session')?.args, { _request: {} })

  const opened = await phone.call('session.open', { sessionId: 'sess-1' })
  const openedValue = opened.value as { items: Array<Record<string, unknown>>; session: { goal?: Record<string, unknown> } }
  const items = openedValue.items
  assert.deepEqual(items.map(item => item.kind), ['user', 'thinking', 'text', 'tool', 'turn'])
  assert.equal(items[3]!.status, 'ok')
  assert.equal(items[3]!.result, 'export function login() {}')
  // Activation is process-local, so opening reads it beside the projection.
  assert.equal(openedValue.session.goal?.activation, 'armed')

  // Live streaming arrives as coalesced deltas.
  followFeed.push({ type: 'assistant-stream', frame: { type: 'start', attemptId: 'att-1', revision: 1, startedAfterSeq: 5, turn: 2, step: 1 } })
  followFeed.push({ type: 'assistant-stream', frame: { type: 'chunk', attemptId: 'att-1', revision: 1, index: 0, time: 1, chunk: { type: 'reasoning-delta', index: 0, text: 'Hmm, ' } } })
  followFeed.push({ type: 'assistant-stream', frame: { type: 'chunk', attemptId: 'att-1', revision: 1, index: 1, time: 2, chunk: { type: 'text-delta', index: 1, text: 'Found it.' } } })
  const live = await phone.event('session.live')
  assert.deepEqual(live.delta, { attemptId: 'att-1', reset: true, thinking: 'Hmm, ', text: 'Found it.' })

  // A durable event is forwarded as an item delta.
  followFeed.push({ type: 'event', event: { type: 'assistant/message', seq: 7, time: 200, data: { turn: 2, step: 1, stream: [], message: { id: 'm9', role: 'assistant', content: [{ type: 'text', text: 'Found it.' }] } } } })
  const delta = await phone.event('session.items')
  assert.equal((delta.items as Array<Record<string, unknown>>)[0]!.text, 'Found it.')

  // Model and thinking level switching.
  const model = await phone.call('session.model', { sessionId: 'sess-1', provider: 'deepseek', model: 'deepseek-v4', effort: 'low' })
  assert.deepEqual(model.value, { provider: 'deepseek', model: 'deepseek-v4', effort: 'low' })

  // Slash commands: listing merges commands and skills; a command runs without a model turn.
  const listed = await phone.call('commands.list', { sessionId: 'sess-1' })
  assert.deepEqual((listed.value as Array<{ name: string }>).map(row => row.name), ['compact', 'review'])
  const ran = await phone.call('session.prompt', { sessionId: 'sess-1', text: '/compact' })
  assert.deepEqual(ran.value, { kind: 'command', text: 'Compacted' })
  const sent = await phone.call('session.prompt', { sessionId: 'sess-1', text: 'Thanks!' })
  assert.deepEqual(sent.value, { kind: 'prompt' })
  const prompt = calls.findLast(call => call.method === 'prompt')!.args.request as Record<string, unknown>
  assert.deepEqual(prompt.content, [{ type: 'text', text: 'Thanks!' }])

  // Mode switching.
  const preset = await phone.call('session.preset', { sessionId: 'sess-1', preset: 'cordis' })
  assert.deepEqual(preset.value, { preset: 'cordis' })

  // A goal mutation carries the projected CAS ref and returns a fresh view.
  const paused = await phone.call('session.goal.pause', { sessionId: 'sess-1', goalId: 'goal-1', revision: 1 })
  assert.equal((paused.value as Record<string, unknown>).phase, 'paused')
  assert.equal((paused.value as Record<string, unknown>).activation, 'disarmed')

  // A continuable child takes a prompt through its exact parent address.
  const childPrompt = await phone.call('session.prompt', { sessionId: 'sess-sub', text: 'Keep digging' })
  assert.deepEqual(childPrompt.value, { kind: 'prompt' })
  const routed = calls.findLast(call => call.namespace === 'subagents' && call.method === 'prompt')
  assert.ok(routed)
  assert.deepEqual(routed.args.request, {
    requestId: (routed.args.request as Record<string, unknown>).requestId,
    parentSessionId: 'sess-1',
    childSessionId: 'sess-sub',
    mode: 'continuable',
    delivery: 'queue',
    content: [{ type: 'text', text: 'Keep digging' }],
  })

  // DeepSeek asks a question; the phone answers it before any Web client does.
  let webNext: (() => void) | undefined
  const asked = emit('user-questions/request', {
    questions: [{ id: 'q1', question: 'Apply the fix?', options: [{ label: 'Yes' }, { label: 'No' }] }],
    agent: { id: 'sess-1', session: { id: 'sess-1' } },
    wait: { callId: 'call-q' },
  }, () => new Promise((_resolve, reject) => { webNext = () => reject(new Error('no web')) })) as Promise<unknown>
  const question = await phone.event('question')
  assert.equal(question.callId, 'call-q')
  assert.equal((question.questions as Array<{ question: string }>)[0]!.question, 'Apply the fix?')
  const answered = await phone.call('question.answer', { sessionId: 'sess-1', callId: 'call-q', answers: [{ id: 'q1', selected: ['Yes'] }] })
  assert.deepEqual(answered.value, { accepted: true })
  assert.deepEqual(await asked, { answers: [{ id: 'q1', selected: ['Yes'] }] })
  webNext?.()

  // A finished turn notifies with the latest reply.
  emit('api-session/status', 'sess-1', true)
  emit('api-session/status', 'sess-1', false)
  const finished = await phone.event('turn.finished')
  assert.equal(finished.title, 'Fix the login bug')
  assert.equal(finished.summary, 'Found it.')

  // Forged messages are dropped, not answered.
  phone.ws.send(JSON.stringify({ t: 'msg', d: Buffer.alloc(64).toString('base64') }))
  const still = await phone.call('sessions.list')
  assert.equal(still.ok, true)

  phone.ws.close()
})

test('a disconnected phone gets an encrypted push from this Mac, not the relay', async () => {
  const phone = await connectPhone()
  const hello = await phone.call('hello', { device: { name: 'Test', model: 'iPhone Duo' } })
  assert.deepEqual((hello.value as { push: unknown }).push, { enabled: true, topic: 'ai.example.duo' })
  const token = 'ab'.repeat(32)
  const registered = await phone.call('push.register', { token, env: 'sandbox', topic: 'ai.example.duo' })
  assert.deepEqual(registered.value, { enabled: true })
  phone.ws.close()

  // Once the relay reports the phone gone, a finished turn becomes a push.
  for (let attempt = 0; attempt < 40 && pushes.length < 2; attempt++) {
    await new Promise(resolve => setTimeout(resolve, 150))
    emit('api-session/status', 'sess-1', true)
    emit('api-session/status', 'sess-1', false)
  }
  assert.deepEqual(pushes.slice(0, 2).map(push => push.env), ['sandbox', 'production'])
  const sent = pushes[1]!
  assert.equal(sent.token, token)
  assert.equal(sent.headers['apns-topic'], 'ai.example.duo')
  assert.match(sent.headers.authorization!, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/)
  const payload = JSON.parse(sent.body) as { aps: { category: string; 'mutable-content': number }; e: string }
  assert.equal(payload.aps['mutable-content'], 1)
  assert.equal(payload.aps.category, 'TURN')
  const opened = phone.sealer.open(payload.e) as { kind: string; sessionId: string; title: string }
  assert.deepEqual([opened.kind, opened.sessionId, opened.title], ['turn', 'sess-1', 'Fix the login bug'])

  // The working environment is remembered for the next push.
  const devices = JSON.parse(await readFile(join(home, 'duo-remote', 'devices.json'), 'utf8')) as Record<string, { env: string }>
  assert.equal(devices['iphone-duo-1']!.env, 'production')
})

test('the iPhone page shows phones, the pairing code, and unpairs everyone', async () => {
  const panel = services.get('duoRemote') as {
    overview(): Promise<{ phones: Array<{ id: string; name: string; online: boolean; notifications: boolean }>; push: { enabled: boolean }; relayConnected: boolean }>
    pairingCode(): Promise<{ link: string; svg: string }>
    unpairAll(): Promise<{ phones: unknown[] }>
    typertRemote: { service: unknown; serviceKey: string; namespace: string }
  }
  assert.ok(panel, 'duoRemote service provided')
  assert.equal(panel.typertRemote.service, panel)
  assert.equal(panel.typertRemote.serviceKey, 'duoRemote')
  assert.deepEqual((manifests[0] as { invocations: Array<{ method: string }> }).invocations.map(item => item.method),
    ['overview', 'pairingCode', 'unpairAll'])

  const overview = await panel.overview()
  assert.equal(overview.push.enabled, true)
  assert.equal(overview.relayConnected, true)
  const phone = overview.phones.find(item => item.id === 'iphone-duo-1')
  assert.ok(phone, 'the phone that said hello is listed')
  assert.equal(phone.name, 'Test')
  assert.equal(phone.notifications, true)

  const before = JSON.parse(await readFile(join(home, 'duo-remote', 'pairing.json'), 'utf8')) as { roomId: string; secret: string }
  const code = await panel.pairingCode()
  assert.match(code.link, /^dshduo:\/\/pair\?v=1&r=/)
  assert.ok(code.link.includes(`i=${before.roomId}`))
  assert.match(code.svg, /^<svg[\s\S]*<\/svg>\s*$/)

  const after = await panel.unpairAll()
  assert.deepEqual(after.phones, [])
  const rotated = JSON.parse(await readFile(join(home, 'duo-remote', 'pairing.json'), 'utf8')) as { roomId: string; secret: string }
  assert.notEqual(rotated.roomId, before.roomId)
  assert.notEqual(rotated.secret, before.secret)
  assert.deepEqual(JSON.parse(await readFile(join(home, 'duo-remote', 'devices.json'), 'utf8')), {})

  // The old credentials no longer open anything; the new room works.
  const stale = new WebSocket(socketUrl(relay, before.roomId, { role: 'device', auth: relayAuth(Buffer.from(before.secret, 'base64url')), device: 'iphone-duo-1' }))
  const staleMessages: string[] = []
  stale.addEventListener('message', event => staleMessages.push(String(event.data)))
  await new Promise(resolve => setTimeout(resolve, 800))
  assert.ok(staleMessages.every(text => !text.includes('"online":true')), 'old room has no host')
  stale.close()
  const fresh = await connectPhone()
  const hello = await fresh.call('hello', { device: { name: 'New phone', model: 'iPhone' } })
  assert.equal(hello.ok, true)
  fresh.ws.close()
})

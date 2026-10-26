/**
 * End to end: real relay process + this plugin on a fake dsh Host + a
 * simulated phone speaking the sealed protocol, exactly as the iOS app does.
 */

import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtemp, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, test } from 'node:test'
import assert from 'node:assert/strict'
import { Sealer, relayAuth } from '../src/crypto.ts'
import type { HostContext, InvokeRemoteRequest, PeerScope } from '../src/host.ts'
import { apply } from '../src/index.ts'
import { socketUrl } from '../src/relay.ts'

const port = 20_000 + Math.floor(Math.random() * 20_000)
const relay = `http://127.0.0.1:${port}`
let server: ChildProcess
let home: string

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
const listeners = new Map<string, Array<(...args: never[]) => unknown>>()
const followFeed = new Feed<Record<string, unknown>>()
const commands: Array<{ name: string }> = []

const summary = {
  sessionId: 'sess-1', agentAvailable: true, updatedAt: 1000, running: false, blank: false, cwd: '/work/app',
  projections: { kind: 'sequenced', asOfSeq: 9, values: {
    title: 'Fix the login bug',
    agentPreset: 'standard',
    modelSelection: { next: { provider: 'deepseek', model: 'deepseek-v4', reasoningEffort: 'high' }, lastUsed: null },
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
        case 'session/list': return { items: [summary] }
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
    return undefined
  }) as HostContext['get'],
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
  const dataDir = await mkdtemp(join(tmpdir(), 'dsh-duo-relay-'))
  server = spawn(process.execPath, [join(import.meta.dirname, '..', '..', 'relay', 'src', 'node.ts')], {
    env: { ...process.env, PORT: String(port), DATA_DIR: dataDir },
    stdio: ['ignore', 'pipe', 'inherit'],
  })
  await new Promise<void>((resolve) => {
    server.stdout!.on('data', (chunk: Buffer) => { if (chunk.toString().includes('listening')) resolve() })
  })
  const stdout = process.stdout.write.bind(process.stdout)
  process.stdout.write = ((chunk: string | Uint8Array) => typeof chunk === 'string' && chunk.includes('DSH Duo') ? true : stdout(chunk)) as typeof process.stdout.write
  apply(ctx, { relay, hostName: 'test-mac' })
})

after(() => { server.kill() })

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

  // Session list request used the fallback wire name.
  assert.deepEqual(calls.find(call => call.method === 'list' && call.namespace === 'session')?.args, { _request: {} })

  const opened = await phone.call('session.open', { sessionId: 'sess-1' })
  const items = (opened.value as { items: Array<Record<string, unknown>> }).items
  assert.deepEqual(items.map(item => item.kind), ['user', 'thinking', 'text', 'tool', 'turn'])
  assert.equal(items[3]!.status, 'ok')
  assert.equal(items[3]!.result, 'export function login() {}')

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

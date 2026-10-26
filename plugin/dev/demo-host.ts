/**
 * Demo Host: runs this plugin against a simulated dsh so the iPhone app can be
 * developed and demoed without a DeepSeek key.
 *
 *   node dev/demo-host.ts --relay http://127.0.0.1:8787
 *
 * Prompts stream back thinking, a tool call and a reply; a prompt containing
 * "ask" makes DeepSeek ask a question; `/compact` runs a command.
 */

import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parseArgs } from 'node:util'
import type { HostContext, InvokeRemoteRequest } from '../src/host.ts'
import { apply } from '../src/index.ts'

const { values: cli } = parseArgs({ options: { relay: { type: 'string', default: 'http://127.0.0.1:8787' }, home: { type: 'string' } } })
const home = cli.home ?? await mkdtemp(join(tmpdir(), 'dsh-duo-demo-'))

class Feed<T> implements AsyncIterable<T> {
  private readonly items: T[] = []
  private waiters: Array<(item: IteratorResult<T>) => void> = []
  private closed = false
  push(item: T): void {
    const waiter = this.waiters.shift()
    if (waiter !== undefined) waiter({ value: item, done: false })
    else this.items.push(item)
  }
  close(): void {
    this.closed = true
    for (const waiter of this.waiters.splice(0)) waiter({ value: undefined, done: true })
  }
  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: () => {
        const item = this.items.shift()
        if (item !== undefined) return Promise.resolve({ value: item, done: false })
        if (this.closed) return Promise.resolve({ value: undefined, done: true })
        return new Promise(resolve => this.waiters.push(resolve))
      },
      return: () => {
        this.close()
        return Promise.resolve({ value: undefined, done: true })
      },
    }
  }
}

type Json = Record<string, unknown>
const listeners = new Map<string, Array<(...args: never[]) => unknown>>()
function emit(event: string, ...args: unknown[]): unknown {
  let result: unknown
  for (const listener of listeners.get(event) ?? []) result = (listener as (...values: unknown[]) => unknown)(...args)
  return result
}

interface DemoSession {
  summary: Json
  events: Json[]
  feeds: Set<Feed<Json>>
  model: Json
  preset: string
  title: string
  turn: number
  /** Prompts sent with mode "queue" during a turn; each runs as its own turn afterwards. */
  queued?: string[]
}

const now = Date.now()
let seq = 100
const sessions = new Map<string, DemoSession>()
function session(id: string, title: string, cwd: string, minutesAgo: number, preset: string, events: Json[]): void {
  sessions.set(id, {
    summary: { sessionId: id, agentAvailable: true, updatedAt: now - minutesAgo * 60_000, running: false, blank: events.length === 0, cwd },
    events,
    feeds: new Set(),
    model: { provider: 'deepseek', model: 'deepseek-v4', reasoningEffort: 'high' },
    preset,
    title,
    turn: 1,
  })
}
function ev(type: string, data: Json, time = now - 3_600_000): Json {
  return { type, seq: seq++, time, data }
}
const user = (text: string): Json => ev('user/message', { id: `m${seq}`, role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text }] })
const assistant = (turn: number, blocks: Json[]): Json => ev('assistant/message', { turn, step: 1, stream: [], message: { id: `m${seq}`, role: 'assistant', content: blocks } })
const result = (turn: number, callId: string, text: string, isError = false): Json =>
  ev('tool/result', { turn, step: 1, message: { id: `m${seq}`, role: 'tool', toolCallId: callId, isError, content: [{ type: 'text', text }] } })

session('s-login', 'Fix flaky login test', '/Users/dev/Code/webapp', 4, 'standard', [
  ev('turn/start', { turn: 1 }),
  user('The login e2e test fails about one run in five. Can you find out why?'),
  assistant(1, [
    { type: 'reasoning', text: 'Intermittent failure → likely a race. Check how the test waits for the session cookie before navigating.' },
    { type: 'text', text: "I'll look at the test and the auth flow first." },
    { type: 'tool-call', id: 'c1', name: 'bash', arguments: '{"command":"npx playwright test login --repeat-each 10"}' },
  ]),
  result(1, 'c1', '10 tests, 2 failed\n  ✘ login › redirects to dashboard (timeout waiting for /dashboard)'),
  assistant(1, [
    { type: 'tool-call', id: 'c2', name: 'read', arguments: '{"path":"tests/e2e/login.spec.ts"}' },
  ]),
  result(1, 'c2', "await page.click('text=Sign in')\nawait page.goto('/dashboard')"),
  assistant(1, [
    { type: 'reasoning', text: "The test navigates before the Set-Cookie response lands. Should wait for the auth response instead of racing goto." },
    { type: 'text', text: "Found it. The test clicks **Sign in** and immediately calls `page.goto('/dashboard')`, racing the auth request:\n\n```ts\nawait page.click('text=Sign in')\nawait page.goto('/dashboard')\n```\n\nWhen the cookie arrives late, the dashboard redirects back to login. The fix is to wait for the auth response:\n\n```ts\nawait Promise.all([\n  page.waitForResponse(r => r.url().endsWith('/api/session') && r.ok()),\n  page.click('text=Sign in'),\n])\n```\n\nWant me to apply it and run the suite 50×?" },
  ]),
  ev('turn/end', { turn: 1, reason: { kind: 'completed' } }),
])
session('s-api', 'Add pagination to /orders API', '/Users/dev/Code/webapp', 52, 'ptc', [
  ev('turn/start', { turn: 1 }),
  user('Add cursor pagination to GET /orders'),
  assistant(1, [
    { type: 'reasoning', text: 'Cursor pagination: encode the last id and created_at so pages stay stable while orders are inserted.' },
    { type: 'tool-call', id: 'c-api-1', name: 'edit', arguments: '{"path":"src/routes/orders.ts"}' },
  ]),
  result(1, 'c-api-1', 'Updated src/routes/orders.ts (+42 −7)'),
  assistant(1, [{ type: 'text', text: 'Done: `GET /orders?cursor=…&limit=50` now returns `{ items, nextCursor }`.\n\n| Endpoint | Before | After |\n|:--|--:|:-:|\n| `GET /orders` | 1.8 s | 120 ms |\n| `GET /orders?status=open` | 950 ms | 85 ms |\n| Page size | all rows | 50 |\n\nTests updated.' }]),
  ev('turn/end', { turn: 1, reason: { kind: 'completed' } }),
])
session('s-plugin', 'Build a standup summary page', '/Users/dev/Code/dsh-plugins', 180, 'cordis', [
  ev('turn/start', { turn: 1 }),
  user('Make me a page that summarizes yesterday’s sessions for standup'),
  assistant(1, [{ type: 'text', text: 'I created the **Standup** page plugin and installed it into your profile. Open it from the sidebar in dsh.' }]),
  ev('turn/end', { turn: 1, reason: { kind: 'completed' } }),
])
session('s-notes', 'Summarize the RFC', '/Users/dev/Documents', 1440, 'minimal', [
  ev('turn/start', { turn: 1 }),
  user('Summarize rfc-0042.md in five bullets'),
  assistant(1, [{ type: 'text', text: '- Moves sessions to a v4 log format\n- Adds migration chain\n- Keeps old files readable\n- No breaking API change\n- Ships behind a flag first' }]),
  ev('turn/end', { turn: 1, reason: { kind: 'completed' } }),
])

const workspaces = [
  { workspaceId: 'w-web', path: '/Users/dev/Code/webapp', title: 'webapp', sessionIds: ['s-login', 's-api'] },
  { workspaceId: 'w-plugins', path: '/Users/dev/Code/dsh-plugins', title: 'dsh-plugins', sessionIds: ['s-plugin'] },
]
const workspaceFeeds = new Set<Feed<Json>>()
const controlFeeds = new Set<Feed<Json>>()

function values(id: string): Json {
  const entry = sessions.get(id)!
  return { title: entry.title, agentPreset: entry.preset, modelSelection: { next: entry.model, lastUsed: entry.model }, workingDirectory: entry.summary.cwd }
}
function summaryOf(id: string): Json {
  return { ...sessions.get(id)!.summary, projections: { kind: 'sequenced', asOfSeq: seq, values: values(id) } }
}
function append(id: string, event: Json): void {
  const entry = sessions.get(id)!
  entry.events.push(event)
  for (const feed of entry.feeds) feed.push({ type: 'event', event })
}
function live(id: string, frame: Json): void {
  for (const feed of sessions.get(id)!.feeds) feed.push({ type: 'assistant-stream', frame })
}
function projection(id: string, key: string, value: unknown): void {
  for (const feed of controlFeeds) feed.push({ type: 'projection', sessionId: id, key, value, seq })
}
const sleep = (ms: number): Promise<void> => new Promise(resolve => setTimeout(resolve, ms))

async function stream(id: string, attemptId: string, kind: 'reasoning-delta' | 'text-delta', text: string): Promise<void> {
  for (const word of text.split(/(?<= )/)) {
    live(id, { type: 'chunk', attemptId, revision: 1, index: 0, time: Date.now(), chunk: { type: kind, index: 0, text: word } })
    await sleep(35)
  }
}

async function runTurn(id: string, prompt: string): Promise<void> {
  const entry = sessions.get(id)!
  const turn = ++entry.turn
  entry.summary = { ...entry.summary, running: true, blank: false, updatedAt: Date.now() }
  if (entry.title === 'New session') {
    entry.title = prompt.slice(0, 48)
    projection(id, 'title', entry.title)
  }
  emit('api-session/activity', id, Date.now())
  emit('api-session/status', id, true)
  append(id, ev('turn/start', { turn }, Date.now()))
  append(id, ev('user/message', { id: `m${seq}`, role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text: prompt }] }, Date.now()))
  await sleep(400)

  const thinking = `The user wants: "${prompt.slice(0, 80)}". I'll inspect the repository, then answer concisely.`
  const attempt = `att-${seq}`
  live(id, { type: 'start', attemptId: attempt, revision: 1, startedAfterSeq: seq, turn, step: 1 })
  await stream(id, attempt, 'reasoning-delta', thinking)
  live(id, { type: 'end', attemptId: attempt, revision: 1, index: 1, outcome: { kind: 'committed', eventType: 'assistant/message', seq } })
  const callId = `call-${seq}`
  append(id, ev('assistant/message', { turn, step: 1, stream: [], message: { id: `m${seq}`, role: 'assistant', content: [
    { type: 'reasoning', text: thinking },
    { type: 'tool-call', id: callId, name: 'bash', arguments: JSON.stringify({ command: 'git status --short && npm test -- --silent' }) },
  ] } }, Date.now()))
  await sleep(1200)
  append(id, ev('tool/result', { turn, step: 1, message: { id: `m${seq}`, role: 'tool', toolCallId: callId, content: [{ type: 'text', text: ' M src/auth/session.ts\n\nTests: 128 passed, 128 total' }] } }, Date.now()))

  if (/\bask\b/i.test(prompt)) {
    const answer = await emit('user-questions/request', {
      questions: [{ id: 'q1', header: 'Deploy', question: 'All tests pass. Should I open a pull request?', options: [
        { label: 'Open PR', description: 'Push a branch and open a draft PR' },
        { label: 'Commit only', description: 'Commit locally, no push' },
        { label: 'Not yet' },
      ] }],
      agent: { id, session: { id } },
      wait: { callId: `ask-${seq}` },
    }, () => Promise.reject(new Error('no web client'))) as { answers: Array<{ selected: string[]; custom?: string }> }
    const choice = answer.answers[0]?.custom ?? answer.answers[0]?.selected[0] ?? 'nothing'
    append(id, ev('user/message', { id: `m${seq}`, role: 'user', source: { kind: 'user-question-reply' }, content: [{ type: 'text', text: choice }] }, Date.now()))
  }

  const reply = `All 128 tests pass and the working tree only has the change in \`src/auth/session.ts\`.\n\n**Summary**\n- Ran the full suite\n- No new warnings\n\nAnything else you'd like me to check?`
  const attempt2 = `att-${seq}`
  live(id, { type: 'start', attemptId: attempt2, revision: 1, startedAfterSeq: seq, turn, step: 2 })
  await stream(id, attempt2, 'text-delta', reply)
  live(id, { type: 'end', attemptId: attempt2, revision: 1, index: 1, outcome: { kind: 'committed', eventType: 'assistant/message', seq } })
  append(id, ev('assistant/message', { turn, step: 2, stream: [], message: { id: `m${seq}`, role: 'assistant', content: [{ type: 'text', text: reply }] } }, Date.now()))
  append(id, ev('turn/end', { turn, reason: { kind: 'completed' } }, Date.now()))
  entry.summary = { ...entry.summary, running: false, updatedAt: Date.now() }
  emit('api-session/status', id, false)
  const next = entry.queued?.shift()
  if (next !== undefined) void runTurn(id, next)
}

const catalog = {
  default: { provider: 'deepseek', model: 'deepseek-v4', reasoningEffort: 'high' },
  routableProviders: ['deepseek'],
  failures: [],
  groups: [{ id: 'deepseek', name: 'DeepSeek', models: [
    { id: 'deepseek-v4', name: 'DeepSeek V4', description: 'Flagship reasoning model',
      reasoning: { efforts: [{ id: 'low', name: 'Low' }, { id: 'medium', name: 'Medium' }, { id: 'high', name: 'High' }, { id: 'max', name: 'Max' }], defaultEffort: 'high' } },
    { id: 'deepseek-v4-flash', name: 'DeepSeek V4 Flash', description: 'Fast and inexpensive',
      reasoning: { efforts: [{ id: 'none', name: 'Off' }, { id: 'low', name: 'Low' }], defaultEffort: 'low' } },
  ] }],
}

async function invoke(request: InvokeRemoteRequest): Promise<unknown> {
  const endpoint = `${request.namespace}/${request.method}`
  const req = (request.args.request ?? {}) as Json
  switch (endpoint) {
    case 'session/list': return { items: [...sessions.keys()].map(summaryOf) }
    case 'agentPresets/list': return { presets: [
      { id: 'standard', name: 'Standard', isDefault: true }, { id: 'ptc', name: 'PTC' },
      { id: 'minimal', name: 'Minimal' }, { id: 'cordis', name: 'Creator' },
    ] }
    case 'session/modelCatalog': return catalog
    case 'session/selectModel': {
      const entry = sessions.get(String(req.sessionId))!
      entry.model = { provider: req.provider, model: req.model, ...req.reasoningEffort === undefined ? {} : { reasoningEffort: req.reasoningEffort } }
      projection(String(req.sessionId), 'modelSelection', { next: entry.model, lastUsed: entry.model })
      return { selected: entry.model }
    }
    case 'agentPresets/select': {
      const entry = sessions.get(String(request.args.agentId))!
      if (!entry.summary.blank) throw Object.assign(new Error('This session has already started'), { code: 'agent-preset/locked' })
      entry.preset = String(request.args.agentPreset)
      projection(String(request.args.agentId), 'agentPreset', entry.preset)
      return entry.preset
    }
    case 'session/create': {
      const id = `s-${Date.now().toString(36)}`
      const workspace = workspaces.find(item => item.workspaceId === req.workspaceId)
      session(id, 'New session', workspace?.path ?? String(req.cwd ?? '/Users/dev'), 0, String(req.agentPreset ?? 'standard'), [])
      sessions.get(id)!.summary.updatedAt = Date.now()
      if (workspace !== undefined) {
        workspace.sessionIds.unshift(id)
        for (const feed of workspaceFeeds) feed.push({ type: 'upsert', workspace })
      }
      emit('api-session/added', summaryOf(id))
      return { sessionId: id, agentPreset: sessions.get(id)!.preset }
    }
    case 'session/rename': {
      sessions.get(String(req.sessionId))!.title = String(req.title)
      projection(String(req.sessionId), 'title', req.title)
      return { title: req.title, seq }
    }
    case 'session/prompt': {
      const content = (req.content as Json[])[0]!
      const id = String(req.sessionId), text = String(content.text)
      const entry = sessions.get(id)!
      // Like dsh: a steer joins the running turn at its next step, a queued prompt waits for the turn to end.
      if (entry.summary.running === true && req.mode === 'steer') {
        setTimeout(() => append(id, ev('user/message', { id: `m${seq}`, role: 'user', source: { kind: 'user-rpc' }, content: [{ type: 'text', text }] }, Date.now())), 1500)
      } else if (entry.summary.running === true) {
        (entry.queued ??= []).push(text)
      } else {
        void runTurn(id, text)
      }
      return { accepted: true }
    }
    case 'session/cancel': return { accepted: true }
    case 'commands/list': return [
      { name: 'compact', description: 'Summarize older history to free context' },
      { name: 'clear', description: 'Start over in a fresh context' },
      { name: 'goal', description: 'Set a goal DeepSeek keeps working toward', input: { hint: '<objective>' } },
      { name: 'duo-pair', description: 'Show DSH Duo pairing status' },
    ]
    case 'skills/list': return { skills: [
      { name: 'code-review', description: 'Review the current diff for bugs', modelInvocable: true },
      { name: 'release-notes', description: 'Draft release notes from merged PRs', modelInvocable: true },
    ] }
    case 'commands/execute': {
      const line = String(request.args.line)
      if (!line.startsWith('/compact') && !line.startsWith('/clear') && !line.startsWith('/goal')) return undefined
      const id = String(request.args.agentId)
      append(id, ev('command/run', { commandId: `k${seq}`, name: line.slice(1).split(' ')[0], source: 'user' }, Date.now()))
      append(id, ev('command/done', { commandId: `k${seq - 1}`, kind: 'success', text: 'Compacted 12 messages into a 340-token summary.' }, Date.now()))
      return { commandId: `k${seq}`, result: { kind: 'success', text: 'Compacted 12 messages into a 340-token summary.' } }
    }
    case 'directoryPicker/list': {
      const path = String(request.args.path ?? '/Users/dev')
      const children = path === '/Users/dev' ? ['Code', 'Documents', 'Desktop', '.config'] : path.endsWith('/Code') ? ['webapp', 'dsh-plugins', 'ios-app', 'infra'] : []
      const parts = path.split('/').filter(Boolean)
      return {
        path, home: '/Users/dev',
        crumbs: parts.map((_, index) => ({ name: parts[index], path: `/${parts.slice(0, index + 1).join('/')}`, hidden: false })),
        entries: children.map(name => ({ name, path: `${path}/${name}`, hidden: name.startsWith('.') })),
      }
    }
    case 'workspace/create': {
      const path = String(req.path)
      const workspace = { workspaceId: `w-${Date.now().toString(36)}`, path, title: path.split('/').pop()!, sessionIds: [] }
      workspaces.push(workspace)
      for (const feed of workspaceFeeds) feed.push({ type: 'upsert', workspace })
      return { workspace, created: true }
    }
    case 'userQuestions/answer': return true
    default: throw Object.assign(new Error(`demo host does not implement ${endpoint}`), { code: 'demo/unimplemented' })
  }
}

const ctx: HostContext = {
  typertGateway: {
    invoke,
    async stream(request) {
      const endpoint = `${request.namespace}/${request.method}`
      const feed = new Feed<Json>()
      request.signal?.addEventListener('abort', () => feed.close())
      if (endpoint === 'session/follow') {
        const address = (request.args.request as Json).address as Json
        const entry = sessions.get(String(address.sessionId))!
        feed.push({ type: 'snapshot', header: {}, cursor: seq, records: entry.events.map(event => ({ type: 'event', event })), hasMore: false, projections: { asOfSeq: seq, values: {} } })
        entry.feeds.add(feed)
        request.signal?.addEventListener('abort', () => entry.feeds.delete(feed))
      } else if (endpoint === 'session/control') {
        feed.push({ type: 'baseline', value: { projections: Object.fromEntries([...sessions.keys()].map(id => [id, { asOfSeq: seq, values: values(id) }])) } })
        controlFeeds.add(feed)
      } else if (endpoint === 'workspace/follow') {
        feed.push({ type: 'baseline', value: { items: workspaces, archivedSessionIds: [], pinnedSessionIds: [] } })
        workspaceFeeds.add(feed)
      }
      return feed
    },
  },
  connection: { createPeer: () => ({ id: 'demo', signal: new AbortController().signal, dispose: async () => {} }) },
  logger: { info: (message: unknown) => console.log(String(message)), warn: (message: unknown) => console.warn(String(message)) },
  get: ((name: string) => name === 'profileContext' ? { home } : undefined) as HostContext['get'],
  on(event, listener) {
    const list = listeners.get(event) ?? []
    list.push(listener)
    listeners.set(event, list)
    return () => { list.splice(list.indexOf(listener), 1) }
  },
}

apply(ctx, { relay: cli.relay, hostName: 'Demo MacBook' })
console.log(`demo host running; pairing file in ${home}/duo-remote/pairing.json`)

import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, test } from 'node:test'
import assert from 'node:assert/strict'

const port = 20_000 + Math.floor(Math.random() * 20_000)
const base = `127.0.0.1:${port}`
let server: ChildProcess

before(async () => {
  const dataDir = await mkdtemp(join(tmpdir(), 'dsh-duo-relay-'))
  server = spawn(process.execPath, [join(import.meta.dirname, '..', 'src', 'node.ts')], {
    env: { ...process.env, PORT: String(port), DATA_DIR: dataDir },
    stdio: ['ignore', 'pipe', 'inherit'],
  })
  await new Promise<void>((resolve) => {
    server.stdout!.on('data', (chunk: Buffer) => { if (chunk.toString().includes('listening')) resolve() })
  })
})

after(() => { server.kill() })

const auth = 'a'.repeat(64)
const room = 'room_abcdefgh1234'

interface Conn { ws: WebSocket; frames: Array<Record<string, unknown>>; next(): Promise<Record<string, unknown>> }

async function open(query: string): Promise<Conn> {
  const ws = new WebSocket(`ws://${base}/v1/rooms/${room}?${query}`)
  const frames: Array<Record<string, unknown>> = []
  const waiters: Array<(frame: Record<string, unknown>) => void> = []
  ws.addEventListener('message', (event) => {
    const frame = JSON.parse(String(event.data)) as Record<string, unknown>
    const waiter = waiters.shift()
    if (waiter === undefined) frames.push(frame)
    else waiter(frame)
  })
  await new Promise<void>((resolve, reject) => {
    ws.addEventListener('open', () => resolve())
    ws.addEventListener('error', () => reject(new Error('socket failed')))
  })
  return {
    ws,
    frames,
    next: () => {
      const queued = frames.shift()
      return queued === undefined ? new Promise(resolve => waiters.push(resolve)) : Promise.resolve(queued)
    },
  }
}

async function rejected(query: string): Promise<boolean> {
  try {
    const conn = await open(query)
    conn.ws.close()
    return false
  } catch {
    return true
  }
}

test('a device cannot join a room before its host registers it', async () => {
  assert.equal(await rejected(`role=device&auth=${auth}&device=phone_0001`), true)
})

test('host registers, devices authenticate, and messages route both ways', async () => {
  const host = await open(`role=host&auth=${auth}`)
  assert.equal(await rejected(`role=device&auth=${'b'.repeat(64)}&device=phone_0001`), true)
  assert.equal(await rejected(`role=host&auth=${'b'.repeat(64)}`), true)

  const phone = await open(`role=device&auth=${auth}&device=phone_0001`)
  assert.deepEqual(await phone.next(), { t: 'host', online: true })
  assert.deepEqual(await host.next(), { t: 'device', id: 'phone_0001', online: true })

  phone.ws.send(JSON.stringify({ t: 'msg', d: 'sealed-up' }))
  assert.deepEqual(await host.next(), { t: 'msg', from: 'phone_0001', d: 'sealed-up' })

  host.ws.send(JSON.stringify({ t: 'msg', to: 'phone_0001', d: 'sealed-down' }))
  assert.deepEqual(await phone.next(), { t: 'msg', d: 'sealed-down' })

  phone.ws.send(JSON.stringify({ t: 'ping' }))
  assert.deepEqual(await phone.next(), { t: 'pong' })

  const reply = await fetch(`http://${base}/v1/rooms/${room}/send`, {
    method: 'POST',
    headers: { authorization: `Bearer ${auth}` },
    body: JSON.stringify({ device: 'phone_0001', d: 'quick-reply' }),
  })
  assert.equal(reply.status, 202)
  assert.deepEqual(await host.next(), { t: 'msg', from: 'phone_0001', d: 'quick-reply' })

  const denied = await fetch(`http://${base}/v1/rooms/${room}/send`, {
    method: 'POST',
    headers: { authorization: `Bearer ${'c'.repeat(64)}` },
    body: JSON.stringify({ device: 'phone_0001', d: 'x' }),
  })
  assert.equal(denied.status, 401)

  host.ws.close()
  assert.deepEqual(await phone.next(), { t: 'host', online: false })
  phone.ws.close()
})

/**
 * Self-hosted relay: `node src/node.ts` (Node 22.18+ runs TypeScript directly).
 *
 * Env: PORT (8787), DATA_DIR (./data). Put TLS in front (Caddy, Fly, Render, ...).
 */

import { createServer, type IncomingMessage } from 'node:http'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { WebSocketServer, type WebSocket } from 'ws'
import {
  admit, announceDevice, announceHost, greetDevice, greetHost, MAX_DEVICES, MAX_FRAME_BYTES,
  onDeviceFrame, onDevicePost, onHostFrame, validAuth, validDeviceId, validRoomId,
  type RoomContext, type RoomRecord, type RoomSockets, type RoomStore, type Sock,
} from './room.ts'

const port = Number(process.env.PORT ?? 8787)
const dataDir = process.env.DATA_DIR ?? join(process.cwd(), 'data')
await mkdir(dataDir, { recursive: true })

class FileStore implements RoomStore {
  private readonly path: string
  private cache: RoomRecord | undefined
  private loaded = false

  constructor(roomId: string) {
    this.path = join(dataDir, `${roomId}.json`)
  }

  async load(): Promise<RoomRecord | undefined> {
    if (this.loaded) return this.cache
    try {
      this.cache = JSON.parse(await readFile(this.path, 'utf8')) as RoomRecord
    } catch {
      this.cache = undefined
    }
    this.loaded = true
    return this.cache
  }

  async save(record: RoomRecord): Promise<void> {
    this.cache = record
    this.loaded = true
    const temp = `${this.path}.${process.pid}.tmp`
    await writeFile(temp, JSON.stringify(record), { mode: 0o600 })
    await rename(temp, this.path)
  }
}

class NodeRoom implements RoomSockets {
  hostSock: WebSocket | undefined
  readonly deviceSocks = new Map<string, WebSocket>()
  readonly store: FileStore

  constructor(roomId: string) {
    this.store = new FileStore(roomId)
  }

  host(): Sock | undefined { return this.hostSock }
  device(id: string): Sock | undefined { return this.deviceSocks.get(id) }
  devices(): Iterable<readonly [string, Sock]> { return this.deviceSocks.entries() }
  idle(): boolean { return this.hostSock === undefined && this.deviceSocks.size === 0 }
}

const rooms = new Map<string, NodeRoom>()
function roomFor(id: string): NodeRoom {
  let room = rooms.get(id)
  if (room === undefined) {
    room = new NodeRoom(id)
    rooms.set(id, room)
  }
  return room
}

function contextFor(room: NodeRoom): RoomContext {
  return { store: room.store, sockets: room }
}

async function readBody(request: IncomingMessage): Promise<string> {
  let size = 0
  const chunks: Buffer[] = []
  for await (const chunk of request) {
    size += (chunk as Buffer).length
    if (size > MAX_FRAME_BYTES) throw new Error('body too large')
    chunks.push(chunk as Buffer)
  }
  return Buffer.concat(chunks).toString('utf8')
}

const ROOM_PATH = /^\/v1\/rooms\/([A-Za-z0-9_-]+)(\/send)?$/

const server = createServer((request, response) => {
  const url = new URL(request.url ?? '/', 'http://relay')
  if (url.pathname === '/healthz') {
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, rooms: rooms.size }))
    return
  }
  const match = ROOM_PATH.exec(url.pathname)
  if (request.method === 'POST' && match?.[2] === '/send' && validRoomId(match[1]!)) {
    const auth = (request.headers.authorization ?? '').replace(/^Bearer\s+/i, '')
    void readBody(request)
      .then(body => onDevicePost(contextFor(roomFor(match[1]!)), auth, body))
      .then((status) => { response.writeHead(status).end() })
      .catch(() => { response.writeHead(400).end() })
    return
  }
  response.writeHead(404).end()
})

const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES, perMessageDeflate: true })
const alive = new WeakMap<WebSocket, boolean>()

server.on('upgrade', (request, socket, head) => {
  void (async () => {
    const url = new URL(request.url ?? '/', 'http://relay')
    const match = ROOM_PATH.exec(url.pathname)
    const role = url.searchParams.get('role')
    const auth = url.searchParams.get('auth') ?? ''
    const deviceId = url.searchParams.get('device') ?? ''
    const reject = (status: number): void => {
      socket.end(`HTTP/1.1 ${status} ${status === 401 ? 'Unauthorized' : 'Rejected'}\r\nConnection: close\r\n\r\n`)
    }
    if (match === null || match[2] !== undefined || !validRoomId(match[1]!) || !validAuth(auth)) return reject(400)
    if (role !== 'host' && role !== 'device') return reject(400)
    if (role === 'device' && !validDeviceId(deviceId)) return reject(400)
    const room = roomFor(match[1]!)
    const admission = await admit(room.store, role, auth)
    if (!admission.ok) return reject(admission.status)
    if (role === 'device' && !room.deviceSocks.has(deviceId) && room.deviceSocks.size >= MAX_DEVICES) return reject(429)
    wss.handleUpgrade(request, socket, head, (ws) => {
      alive.set(ws, true)
      ws.on('pong', () => alive.set(ws, true))
      const context = contextFor(room)
      if (role === 'host') {
        room.hostSock?.close(4000, 'replaced')
        room.hostSock = ws
        greetHost(room, ws)
        announceHost(room, true)
        ws.on('message', (data) => { void onHostFrame(context, ws, data.toString()) })
        ws.on('close', () => {
          if (room.hostSock !== ws) return
          room.hostSock = undefined
          announceHost(room, false)
          if (room.idle()) rooms.delete(match[1]!)
        })
      } else {
        room.deviceSocks.get(deviceId)?.close(4000, 'replaced')
        room.deviceSocks.set(deviceId, ws)
        greetDevice(room, ws)
        announceDevice(room, deviceId, true)
        ws.on('message', (data) => { void onDeviceFrame(context, ws, deviceId, data.toString()) })
        ws.on('close', () => {
          if (room.deviceSocks.get(deviceId) !== ws) return
          room.deviceSocks.delete(deviceId)
          announceDevice(room, deviceId, false)
          if (room.idle()) rooms.delete(match[1]!)
        })
      }
    })
  })().catch(() => socket.destroy())
})

// Mobile networks silently drop idle TCP; protocol pings keep NATs open and reap dead peers.
setInterval(() => {
  for (const ws of wss.clients) {
    if (alive.get(ws) === false) {
      ws.terminate()
      continue
    }
    alive.set(ws, false)
    ws.ping()
  }
}, 25_000).unref()

server.listen(port, () => {
  console.log(`dsh-duo relay listening on :${port}`)
})

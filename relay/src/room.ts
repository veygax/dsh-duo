/**
 * Transport-neutral room logic shared by the Node and Cloudflare adapters.
 *
 * A room joins one Host (the dsh plugin) with any number of Devices. Message
 * bodies are sealed end to end; the relay only reads the routing envelope and
 * holds no Apple credentials (each Host sends its own pushes).
 */

/** Minimal socket surface both runtimes provide. */
export interface Sock {
  send(text: string): void
  close(code?: number, reason?: string): void
}

/** Durable room state. Only a hash of the room credential is ever stored. */
export interface RoomRecord {
  readonly authHash: string
  readonly createdAt: number
}

export interface RoomStore {
  load(): Promise<RoomRecord | undefined>
  save(record: RoomRecord): Promise<void>
}

/** Live sockets currently attached to a room. */
export interface RoomSockets {
  host(): Sock | undefined
  device(id: string): Sock | undefined
  devices(): Iterable<readonly [string, Sock]>
}

export const MAX_FRAME_BYTES = 4 * 1024 * 1024
export const MAX_DEVICES = 16
const ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/
const AUTH_PATTERN = /^[0-9a-f]{64}$/

export function validRoomId(id: string): boolean {
  return ID_PATTERN.test(id)
}

export function validDeviceId(id: string): boolean {
  return ID_PATTERN.test(id)
}

export function validAuth(auth: string): boolean {
  return AUTH_PATTERN.test(auth)
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('')
}

function sameText(left: string, right: string): boolean {
  if (left.length !== right.length) return false
  let diff = 0
  for (let index = 0; index < left.length; index++) diff |= left.charCodeAt(index) ^ right.charCodeAt(index)
  return diff === 0
}

export type Admission =
  | { readonly ok: true; readonly record: RoomRecord }
  | { readonly ok: false; readonly status: 401 | 404 }

/**
 * Check a credential. The first Host connection registers the room; Devices
 * can only join a room that exists.
 */
export async function admit(store: RoomStore, role: 'host' | 'device', auth: string): Promise<Admission> {
  const hash = await sha256Hex(auth)
  const record = await store.load()
  if (record === undefined) {
    if (role === 'device') return { ok: false, status: 404 }
    const created: RoomRecord = { authHash: hash, createdAt: Date.now() }
    await store.save(created)
    return { ok: true, record: created }
  }
  return sameText(record.authHash, hash) ? { ok: true, record } : { ok: false, status: 401 }
}

function parse(text: string): Record<string, unknown> | undefined {
  if (text.length > MAX_FRAME_BYTES) return undefined
  try {
    const value: unknown = JSON.parse(text)
    return typeof value === 'object' && value !== null && !Array.isArray(value)
      ? value as Record<string, unknown>
      : undefined
  } catch {
    return undefined
  }
}

function str(value: unknown, max = MAX_FRAME_BYTES): string | undefined {
  return typeof value === 'string' && value.length > 0 && value.length <= max ? value : undefined
}

function trySend(sock: Sock | undefined, frame: object): boolean {
  if (sock === undefined) return false
  try {
    sock.send(JSON.stringify(frame))
    return true
  } catch {
    return false
  }
}

/** Tell the Host and every Device who is present after a connection change. */
export function announceHost(sockets: RoomSockets, online: boolean): void {
  for (const [, sock] of sockets.devices()) trySend(sock, { t: 'host', online })
}

export function announceDevice(sockets: RoomSockets, id: string, online: boolean): void {
  trySend(sockets.host(), { t: 'device', id, online })
}

/** Greeting sent to a socket right after it is admitted. */
export function greetHost(sockets: RoomSockets, sock: Sock): void {
  for (const [id] of sockets.devices()) trySend(sock, { t: 'device', id, online: true })
}

export function greetDevice(sockets: RoomSockets, sock: Sock): void {
  trySend(sock, { t: 'host', online: sockets.host() !== undefined })
}

export interface RoomContext {
  readonly store: RoomStore
  readonly sockets: RoomSockets
}

export async function onHostFrame(room: RoomContext, sock: Sock, text: string): Promise<void> {
  const frame = parse(text)
  if (frame === undefined) return
  switch (frame.t) {
    case 'ping':
      trySend(sock, { t: 'pong' })
      return
    case 'msg': {
      const body = str(frame.d)
      if (body === undefined) return
      const to = str(frame.to, 64)
      if (to !== undefined) {
        trySend(room.sockets.device(to), { t: 'msg', d: body })
        return
      }
      for (const [, device] of room.sockets.devices()) trySend(device, { t: 'msg', d: body })
      return
    }
    default:
  }
}

export async function onDeviceFrame(room: RoomContext, sock: Sock, deviceId: string, text: string): Promise<void> {
  const frame = parse(text)
  if (frame === undefined) return
  switch (frame.t) {
    case 'ping':
      trySend(sock, { t: 'pong' })
      return
    case 'msg': {
      const body = str(frame.d)
      if (body === undefined) return
      if (!trySend(room.sockets.host(), { t: 'msg', from: deviceId, d: body })) trySend(sock, { t: 'host', online: false })
      return
    }
    default:
  }
}

/**
 * Deliver one sealed message from a Device that has no socket open, as a
 * notification quick reply does.
 * @returns HTTP status for the caller.
 */
export async function onDevicePost(room: RoomContext, auth: string, body: string): Promise<number> {
  if (!validAuth(auth)) return 401
  const admission = await admit(room.store, 'device', auth)
  if (!admission.ok) return admission.status
  const frame = parse(body)
  const device = str(frame?.device, 64)
  const sealed = str(frame?.d)
  if (device === undefined || !validDeviceId(device) || sealed === undefined) return 400
  return trySend(room.sockets.host(), { t: 'msg', from: device, d: sealed }) ? 202 : 503
}

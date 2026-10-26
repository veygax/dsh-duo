/**
 * Cloudflare Workers relay: one Durable Object per room, using the WebSocket
 * Hibernation API so idle rooms cost nothing. Deploy with `npx wrangler deploy`.
 *
 * Secrets (optional, enable pushes): APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_TOPIC.
 */

import { apnsConfigFrom, createApnsSender } from './apns.ts'
import {
  admit, announceDevice, announceHost, greetDevice, greetHost, MAX_DEVICES,
  onDeviceFrame, onDevicePost, onHostFrame, validAuth, validDeviceId, validRoomId,
  type PushSender, type RoomContext, type RoomRecord, type RoomSockets, type RoomStore, type Sock,
} from './room.ts'

interface Env {
  ROOMS: DurableObjectNamespace
  APNS_KEY_ID?: string
  APNS_TEAM_ID?: string
  APNS_PRIVATE_KEY?: string
  APNS_TOPIC?: string
}

interface Attachment {
  readonly role: 'host' | 'device'
  readonly device?: string
}

const ROOM_PATH = /^\/v1\/rooms\/([A-Za-z0-9_-]+)(\/send)?$/

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    if (url.pathname === '/healthz') {
      return Response.json({ ok: true, push: apnsConfigFrom(env as unknown as Record<string, string>) !== undefined })
    }
    const match = ROOM_PATH.exec(url.pathname)
    if (match === null || !validRoomId(match[1]!)) return new Response('not found', { status: 404 })
    return await env.ROOMS.get(env.ROOMS.idFromName(match[1]!)).fetch(request)
  },
}

export class Room implements DurableObject {
  private readonly push: PushSender | undefined
  private readonly state: DurableObjectState

  constructor(state: DurableObjectState, env: Env) {
    this.state = state
    const config = apnsConfigFrom(env as unknown as Record<string, string>)
    this.push = config === undefined ? undefined : createApnsSender(config, async (target, headers, body) => {
      const response = await fetch(target, { method: 'POST', headers, body })
      const text = await response.text()
      let reason: string | undefined
      try { reason = (JSON.parse(text) as { reason?: string }).reason } catch { /* empty on success */ }
      return { status: response.status, reason }
    })
  }

  private readonly store: RoomStore = {
    load: async () => await this.state.storage.get<RoomRecord>('room'),
    save: async (record) => { await this.state.storage.put('room', record) },
  }

  private readonly sockets: RoomSockets = {
    host: () => this.state.getWebSockets('host')[0],
    device: (id: string) => this.state.getWebSockets(`device:${id}`)[0],
    devices: () => this.state.getWebSockets('device').map((ws) => {
      const attachment = ws.deserializeAttachment() as Attachment
      return [attachment.device!, ws as Sock] as const
    }),
  }

  private context(): RoomContext {
    return { store: this.store, sockets: this.sockets, push: this.push }
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url)
    const match = ROOM_PATH.exec(url.pathname)!
    if (match[2] === '/send') {
      if (request.method !== 'POST') return new Response(null, { status: 405 })
      const auth = (request.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '')
      return new Response(null, { status: await onDevicePost(this.context(), auth, await request.text()) })
    }
    if (request.headers.get('upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 })
    const role = url.searchParams.get('role')
    const auth = url.searchParams.get('auth') ?? ''
    const device = url.searchParams.get('device') ?? ''
    if ((role !== 'host' && role !== 'device') || !validAuth(auth)) return new Response(null, { status: 400 })
    if (role === 'device' && !validDeviceId(device)) return new Response(null, { status: 400 })
    const admission = await admit(this.store, role, auth)
    if (!admission.ok) return new Response(null, { status: admission.status })

    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    if (role === 'host') {
      for (const old of this.state.getWebSockets('host')) old.close(4000, 'replaced')
      this.state.acceptWebSocket(server, ['host'])
      server.serializeAttachment({ role } satisfies Attachment)
      greetHost(this.sockets, server)
      announceHost(this.sockets, true)
    } else {
      for (const old of this.state.getWebSockets(`device:${device}`)) old.close(4000, 'replaced')
      if (this.state.getWebSockets('device').length >= MAX_DEVICES) return new Response(null, { status: 429 })
      this.state.acceptWebSocket(server, ['device', `device:${device}`])
      server.serializeAttachment({ role, device } satisfies Attachment)
      greetDevice(this.sockets, server)
      announceDevice(this.sockets, device, true)
    }
    this.state.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"t":"ping"}', '{"t":"pong"}'))
    return new Response(null, { status: 101, webSocket: client })
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const text = typeof message === 'string' ? message : new TextDecoder().decode(message)
    const attachment = ws.deserializeAttachment() as Attachment
    if (attachment.role === 'host') await onHostFrame(this.context(), ws, text)
    else await onDeviceFrame(this.context(), ws, attachment.device!, text)
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    const attachment = ws.deserializeAttachment() as Attachment
    if (attachment.role === 'host') {
      if (this.state.getWebSockets('host').every(other => other === ws)) announceHost(this.sockets, false)
    } else if (attachment.device !== undefined) {
      announceDevice(this.sockets, attachment.device, false)
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws)
  }
}

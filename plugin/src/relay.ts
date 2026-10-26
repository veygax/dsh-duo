/** Outbound, self-healing connection from the Host to the relay. */

export interface RelayLinkOptions {
  readonly relay: string
  readonly roomId: string
  readonly auth: string
  readonly onMessage: (from: string, sealed: string) => void
  readonly onDevice: (id: string, online: boolean) => void
  readonly onState?: (connected: boolean) => void
  readonly log: { info(message: string): void; warn(message: string): void }
}

export interface PushMeta {
  readonly category?: string
  readonly thread?: string
  readonly collapse?: string
}

const PING_MS = 20_000
const MAX_BACKOFF_MS = 30_000

export function socketUrl(relay: string, roomId: string, query: Record<string, string>): string {
  const url = new URL(`/v1/rooms/${roomId}`, relay)
  url.protocol = url.protocol === 'http:' ? 'ws:' : 'wss:'
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value)
  return url.toString()
}

export class RelayLink {
  readonly devices = new Set<string>()
  private socket: WebSocket | undefined
  private stopped = false
  private attempt = 0
  private retry: ReturnType<typeof setTimeout> | undefined
  private pinger: ReturnType<typeof setInterval> | undefined
  private lastSeen = 0
  private warned = false
  private readonly options: RelayLinkOptions

  constructor(options: RelayLinkOptions) {
    this.options = options
  }

  get connected(): boolean {
    return this.socket?.readyState === WebSocket.OPEN
  }

  start(): void {
    this.stopped = false
    this.open()
  }

  stop(): void {
    this.stopped = true
    clearTimeout(this.retry)
    clearInterval(this.pinger)
    this.socket?.close(1000, 'host stopping')
    this.socket = undefined
    this.devices.clear()
  }

  /** Send one sealed body to a device, or to every device when `to` is omitted. */
  send(sealed: string, to?: string): void {
    this.raw(to === undefined ? { t: 'msg', d: sealed } : { t: 'msg', to, d: sealed })
  }

  /** Ask the relay to push one sealed notification to every registered, disconnected device. */
  push(sealed: string, meta: PushMeta = {}): void {
    this.raw({ t: 'push', d: sealed, ...meta })
  }

  private raw(frame: object): void {
    if (this.socket?.readyState !== WebSocket.OPEN) return
    try {
      this.socket.send(JSON.stringify(frame))
    } catch (error) {
      this.options.log.warn(`duo relay send failed: ${String(error)}`)
    }
  }

  private open(): void {
    if (this.stopped) return
    const url = socketUrl(this.options.relay, this.options.roomId, { role: 'host', auth: this.options.auth })
    const socket = new WebSocket(url)
    this.socket = socket
    socket.addEventListener('open', () => {
      this.attempt = 0
      this.warned = false
      this.lastSeen = Date.now()
      this.options.log.info(`duo relay connected (${new URL(this.options.relay).host})`)
      this.options.onState?.(true)
      clearInterval(this.pinger)
      this.pinger = setInterval(() => this.heartbeat(socket), PING_MS)
    })
    socket.addEventListener('message', (event) => {
      this.lastSeen = Date.now()
      this.receive(String(event.data))
    })
    socket.addEventListener('close', (event) => {
      if (this.socket !== socket) return
      clearInterval(this.pinger)
      this.socket = undefined
      for (const id of this.devices) this.options.onDevice(id, false)
      this.devices.clear()
      this.options.onState?.(false)
      if (event.code === 4000) this.options.log.warn('duo relay: another dsh process took over this pairing')
      this.schedule()
    })
    socket.addEventListener('error', () => {
      if (!this.warned) this.options.log.warn(`duo relay unreachable at ${this.options.relay}; retrying`)
      this.warned = true
    })
  }

  private heartbeat(socket: WebSocket): void {
    if (Date.now() - this.lastSeen > PING_MS * 2.5) {
      socket.close(4001, 'heartbeat timeout')
      return
    }
    this.raw({ t: 'ping' })
  }

  private schedule(): void {
    if (this.stopped) return
    const base = Math.min(MAX_BACKOFF_MS, 1000 * 2 ** this.attempt++)
    this.retry = setTimeout(() => this.open(), base / 2 + Math.random() * base / 2)
    this.retry.unref?.()
  }

  private receive(text: string): void {
    let frame: { t?: string; from?: string; d?: string; id?: string; online?: boolean }
    try {
      frame = JSON.parse(text) as typeof frame
    } catch {
      return
    }
    switch (frame.t) {
      case 'msg':
        if (typeof frame.from === 'string' && typeof frame.d === 'string') this.options.onMessage(frame.from, frame.d)
        return
      case 'device':
        if (typeof frame.id !== 'string') return
        if (frame.online === true) this.devices.add(frame.id)
        else this.devices.delete(frame.id)
        this.options.onDevice(frame.id, frame.online === true)
        return
      default:
    }
  }
}

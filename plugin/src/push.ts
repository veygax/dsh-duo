/**
 * APNs delivery from this Mac. Each person signs their own copy of the app,
 * so the Apple push key belongs with their dsh, not with the shared relay:
 * `ios/scripts/install.sh` writes `apns.json` next to the pairing record and
 * this module sends pushes straight to Apple over HTTP/2.
 */

import { createPrivateKey, createSign, type KeyObject } from 'node:crypto'
import { readFile, rename, writeFile } from 'node:fs/promises'
import { connect, type ClientHttp2Session } from 'node:http2'
import { dirname, isAbsolute, join } from 'node:path'

/** `$DSH_HOME/duo-remote/apns.json` */
export interface ApnsSettings {
  /** 10-character key identifier of the AuthKey_XXXX.p8 file. */
  readonly keyId: string
  /** 10-character Team ID that signed the app. */
  readonly teamId: string
  /** Path to the .p8 key, absolute or relative to apns.json. */
  readonly keyFile: string
  /** The signed app's bundle identifier. */
  readonly topic: string
}

export type ApnsEnvironment = 'sandbox' | 'production'

export interface DeviceToken {
  readonly token: string
  env: ApnsEnvironment
  readonly updatedAt: number
}

/** Opaque notification body plus APNs presentation hints. */
export interface PushMessage {
  readonly sealed: string
  readonly category?: string
  readonly thread?: string
  readonly collapse?: string
}

/** Delivers one message to one device token; resolves to the APNs status and reason. */
export type ApnsTransport = (
  env: ApnsEnvironment,
  token: string,
  headers: Record<string, string>,
  body: string,
) => Promise<{ status: number; reason?: string }>

/** Reasons that mean this token will never work again for this app. */
const DEAD_REASONS = new Set(['Unregistered', 'DeviceTokenNotForTopic'])

/** Build the alert payload; the Notification Service Extension rewrites it after decrypting `e`. */
export function apnsPayload(message: PushMessage): string {
  return JSON.stringify({
    aps: {
      'alert': { title: 'DeepSeek Harness', body: 'New activity' },
      'sound': 'default',
      'mutable-content': 1,
      ...message.category === undefined ? {} : { category: message.category },
      ...message.thread === undefined ? {} : { 'thread-id': message.thread },
    },
    e: message.sealed,
  })
}

/** HTTP/2 transport with one pooled session per APNs host. */
export function http2Transport(): ApnsTransport & { close(): void } {
  const sessions = new Map<ApnsEnvironment, ClientHttp2Session>()
  const sessionFor = (env: ApnsEnvironment): ClientHttp2Session => {
    let session = sessions.get(env)
    if (session === undefined || session.closed || session.destroyed) {
      session = connect(env === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com')
      session.on('error', () => sessions.delete(env))
      session.on('close', () => sessions.delete(env))
      // Close idle connections so a quiet Host holds nothing open; in-flight pushes keep it referenced.
      session.setTimeout(60_000, () => session?.close())
      sessions.set(env, session)
    }
    return session
  }
  const transport = (env: ApnsEnvironment, token: string, headers: Record<string, string>, body: string) =>
    new Promise<{ status: number; reason?: string }>((resolve, reject) => {
      const request = sessionFor(env).request({ ':method': 'POST', ':path': `/3/device/${token}`, ...headers })
      let status = 0
      let text = ''
      request.setEncoding('utf8')
      request.setTimeout(15_000, () => request.close())
      request.on('response', (head) => { status = Number(head[':status']) })
      request.on('data', (chunk: string) => { text += chunk })
      request.on('error', reject)
      request.on('end', () => {
        let reason: string | undefined
        try { reason = (JSON.parse(text) as { reason?: string }).reason } catch { /* empty body on success */ }
        resolve({ status, reason })
      })
      request.end(body)
    })
  return Object.assign(transport, { close: () => { for (const session of sessions.values()) session.close() } })
}

function base64url(input: Buffer | string): string {
  return Buffer.from(input).toString('base64url')
}

export class ApnsSender {
  private readonly settings: ApnsSettings
  private readonly key: KeyObject
  private readonly transport: ApnsTransport
  private cached: { token: string; at: number } | undefined

  constructor(settings: ApnsSettings, privateKey: string, transport: ApnsTransport) {
    this.settings = settings
    this.key = createPrivateKey(privateKey)
    this.transport = transport
  }

  get topic(): string {
    return this.settings.topic
  }

  private bearer(): string {
    const now = Math.floor(Date.now() / 1000)
    // Apple rejects tokens older than an hour and throttles refreshes faster than 20 minutes.
    if (this.cached !== undefined && now - this.cached.at < 45 * 60) return this.cached.token
    const unsigned = `${base64url(JSON.stringify({ alg: 'ES256', kid: this.settings.keyId }))}.${base64url(JSON.stringify({ iss: this.settings.teamId, iat: now }))}`
    const signature = createSign('sha256').update(unsigned).sign({ key: this.key, dsaEncoding: 'ieee-p1363' })
    this.cached = { token: `${unsigned}.${base64url(signature)}`, at: now }
    return this.cached.token
  }

  /**
   * Deliver to one device. A token minted for the other APNs environment is retried
   * there once (the phone may be a development or a distribution build).
   * @returns `delivered`, or `dead` when Apple says the token is gone; other failures throw.
   */
  async send(device: DeviceToken, message: PushMessage): Promise<'delivered' | 'dead'> {
    const headers: Record<string, string> = {
      'authorization': `bearer ${this.bearer()}`,
      'apns-topic': this.settings.topic,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      ...message.collapse === undefined ? {} : { 'apns-collapse-id': message.collapse },
    }
    const body = apnsPayload(message)
    for (const env of [device.env, device.env === 'sandbox' ? 'production' : 'sandbox'] as const) {
      const result = await this.transport(env, device.token, headers, body)
      if (result.status === 200) {
        device.env = env
        return 'delivered'
      }
      if (result.status === 410 || DEAD_REASONS.has(result.reason ?? '')) return 'dead'
      // BadDeviceToken from one environment means the token belongs to the other.
      if (result.reason !== 'BadDeviceToken') throw new Error(`APNs ${result.status} ${result.reason ?? ''}`.trim())
    }
    return 'dead'
  }
}

/** Load `apns.json` and its key; undefined when this Mac has no push setup. */
export async function loadApns(path: string, transport: ApnsTransport): Promise<ApnsSender | undefined> {
  let settings: ApnsSettings
  try {
    settings = JSON.parse(await readFile(path, 'utf8')) as ApnsSettings
  } catch {
    return undefined
  }
  const keyFile = isAbsolute(settings.keyFile) ? settings.keyFile : join(dirname(path), settings.keyFile)
  return new ApnsSender(settings, await readFile(keyFile, 'utf8'), transport)
}

/** Push tokens of paired phones, persisted beside the pairing record. */
export class DeviceTokens {
  private readonly path: string
  private tokens: Record<string, DeviceToken> = {}

  constructor(path: string) {
    this.path = path
  }

  async load(): Promise<void> {
    try {
      this.tokens = JSON.parse(await readFile(this.path, 'utf8')) as Record<string, DeviceToken>
    } catch {
      this.tokens = {}
    }
  }

  entries(): [string, DeviceToken][] {
    return Object.entries(this.tokens)
  }

  async set(deviceId: string, token: string, env: ApnsEnvironment): Promise<void> {
    // A token belongs to one install; drop it from any other device id that held it.
    for (const [id, entry] of Object.entries(this.tokens)) if (entry.token === token && id !== deviceId) delete this.tokens[id]
    this.tokens[deviceId] = { token, env, updatedAt: Date.now() }
    await this.save()
  }

  async remove(deviceId: string): Promise<void> {
    if (this.tokens[deviceId] === undefined) return
    delete this.tokens[deviceId]
    await this.save()
  }

  async save(): Promise<void> {
    const temp = `${this.path}.${process.pid}.tmp`
    await writeFile(temp, JSON.stringify(this.tokens, null, 2), { mode: 0o600 })
    await rename(temp, this.path)
  }
}

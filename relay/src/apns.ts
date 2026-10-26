/**
 * APNs token-based authentication and payload construction. Signing uses
 * WebCrypto so it runs unchanged on Node and Cloudflare Workers; each adapter
 * supplies the HTTP/2 request itself.
 */

import type { PushRegistration, PushRequest, PushSender } from './room.ts'

export interface ApnsConfig {
  /** 10-character key identifier from the Apple Developer portal. */
  readonly keyId: string
  /** 10-character Team ID. */
  readonly teamId: string
  /** Contents of the AuthKey_XXXX.p8 file. */
  readonly privateKey: string
  /** App bundle identifier. */
  readonly topic: string
}

/** One HTTP/2 POST to APNs; returns the status and the `reason` from the body. */
export type ApnsPost = (
  url: string,
  headers: Record<string, string>,
  body: string,
) => Promise<{ status: number; reason?: string }>

const PERMANENT_REASONS = new Set(['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'])

function base64url(bytes: Uint8Array | string): string {
  const raw = typeof bytes === 'string' ? new TextEncoder().encode(bytes) : bytes
  let binary = ''
  for (const byte of raw) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

async function importKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\s+/g, '')
  const der = Uint8Array.from(atob(body), char => char.charCodeAt(0))
  return await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
}

/** Build the alert payload; the Notification Service Extension rewrites it after decrypting `e`. */
export function apnsPayload(request: PushRequest): string {
  return JSON.stringify({
    aps: {
      'alert': { title: 'DeepSeek Harness', body: 'New activity' },
      'sound': 'default',
      'mutable-content': 1,
      ...request.category === undefined ? {} : { category: request.category },
      ...request.thread === undefined ? {} : { 'thread-id': request.thread },
    },
    e: request.sealed,
  })
}

export function createApnsSender(config: ApnsConfig, post: ApnsPost): PushSender {
  let cached: { token: string; at: number } | undefined
  let key: Promise<CryptoKey> | undefined

  async function bearer(): Promise<string> {
    const now = Math.floor(Date.now() / 1000)
    // Apple rejects tokens older than an hour and throttles refreshes faster than 20 minutes.
    if (cached !== undefined && now - cached.at < 45 * 60) return cached.token
    key ??= importKey(config.privateKey)
    const header = base64url(JSON.stringify({ alg: 'ES256', kid: config.keyId }))
    const claims = base64url(JSON.stringify({ iss: config.teamId, iat: now }))
    const signature = await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' }, await key, new TextEncoder().encode(`${header}.${claims}`))
    cached = { token: `${header}.${claims}.${base64url(new Uint8Array(signature))}`, at: now }
    return cached.token
  }

  return {
    async send(registrations: readonly PushRegistration[], request: PushRequest): Promise<readonly string[]> {
      const authorization = `bearer ${await bearer()}`
      const body = apnsPayload(request)
      const dead: string[] = []
      await Promise.all(registrations.map(async (registration) => {
        const host = registration.env === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com'
        const headers: Record<string, string> = {
          'authorization': authorization,
          'apns-topic': config.topic,
          'apns-push-type': 'alert',
          'apns-priority': '10',
          ...request.collapse === undefined ? {} : { 'apns-collapse-id': request.collapse },
        }
        try {
          const result = await post(`https://${host}/3/device/${registration.token}`, headers, body)
          if (result.status === 410 || (result.status === 400 && PERMANENT_REASONS.has(result.reason ?? ''))) {
            dead.push(registration.token)
          }
        } catch (error) {
          console.warn('apns delivery failed', error)
        }
      }))
      return dead
    },
  }
}

/** Read APNs settings from environment-style variables; undefined disables pushes. */
export function apnsConfigFrom(env: Record<string, string | undefined>): ApnsConfig | undefined {
  const keyId = env.APNS_KEY_ID
  const teamId = env.APNS_TEAM_ID
  const privateKey = env.APNS_PRIVATE_KEY?.replace(/\\n/g, '\n')
  const topic = env.APNS_TOPIC ?? 'ai.deepseek.harness.duo'
  if (keyId === undefined || teamId === undefined || privateKey === undefined) return undefined
  return { keyId, teamId, privateKey, topic }
}

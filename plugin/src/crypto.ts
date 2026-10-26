/** End-to-end sealing shared with the iOS app (see docs/PROTOCOL.md §2). */

import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from 'node:crypto'

const SALT = Buffer.from('dsh-duo')
const AAD = Buffer.from('dsh-duo/v1')

export function deriveKey(secret: Buffer, info: 'relay-auth' | 'e2e-v1'): Buffer {
  return Buffer.from(hkdfSync('sha256', secret, SALT, Buffer.from(info), 32))
}

/** Room credential presented to the relay. */
export function relayAuth(secret: Buffer): string {
  return deriveKey(secret, 'relay-auth').toString('hex')
}

export class Sealer {
  private readonly key: Buffer

  constructor(secret: Buffer) {
    this.key = deriveKey(secret, 'e2e-v1')
  }

  /** @returns base64(nonce ‖ ciphertext ‖ tag), CryptoKit's `SealedBox.combined`. */
  seal(value: unknown): string {
    const nonce = randomBytes(12)
    const cipher = createCipheriv('aes-256-gcm', this.key, nonce)
    cipher.setAAD(AAD)
    const body = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()])
    return Buffer.concat([nonce, body, cipher.getAuthTag()]).toString('base64')
  }

  /** @returns the decoded JSON value, or undefined when the box was forged or corrupted. */
  open(sealed: string): unknown {
    try {
      const raw = Buffer.from(sealed, 'base64')
      if (raw.length < 28) return undefined
      const decipher = createDecipheriv('aes-256-gcm', this.key, raw.subarray(0, 12))
      decipher.setAAD(AAD)
      decipher.setAuthTag(raw.subarray(raw.length - 16))
      const text = Buffer.concat([decipher.update(raw.subarray(12, raw.length - 16)), decipher.final()]).toString('utf8')
      return JSON.parse(text) as unknown
    } catch {
      return undefined
    }
  }
}

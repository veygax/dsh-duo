/** The Host's pairing record: room identity, shared secret, and the relay that joins them. */

import { randomBytes } from 'node:crypto'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { homedir, hostname } from 'node:os'
import { dirname, join } from 'node:path'
import QRCode from 'qrcode'

export interface Pairing {
  readonly roomId: string
  /** base64url of 32 random bytes. */
  readonly secret: string
  readonly relay: string
  /** Set once any device has connected; questions are only held for a phone after that. */
  readonly paired?: boolean
}

export function dshHome(configured?: string): string {
  return configured ?? process.env.DSH_HOME ?? join(homedir(), '.dsh')
}

export function pairingPath(home: string): string {
  return join(home, 'duo-remote', 'pairing.json')
}

function fresh(relay: string): Pairing {
  return {
    roomId: randomBytes(16).toString('base64url'),
    secret: randomBytes(32).toString('base64url'),
    relay,
  }
}

export async function savePairing(path: string, pairing: Pairing): Promise<void> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temp = `${path}.${process.pid}.tmp`
  await writeFile(temp, `${JSON.stringify(pairing, null, 2)}\n`, { mode: 0o600 })
  await rename(temp, path)
}

/**
 * Load the pairing record, creating it on first run. A relay configured in
 * the plugin row wins over the stored one so a deployment can move relays
 * without un-pairing devices.
 */
export async function loadPairing(path: string, relay: string): Promise<Pairing> {
  let stored: Pairing | undefined
  try {
    stored = JSON.parse(await readFile(path, 'utf8')) as Pairing
  } catch {
    stored = undefined
  }
  if (stored === undefined || typeof stored.roomId !== 'string' || typeof stored.secret !== 'string') {
    const created = fresh(relay)
    await savePairing(path, created)
    return created
  }
  if (stored.relay !== relay) {
    stored = { ...stored, relay }
    await savePairing(path, stored)
  }
  return stored
}

export async function rotatePairing(path: string, relay: string): Promise<Pairing> {
  const created = fresh(relay)
  await savePairing(path, created)
  return created
}

export function pairingLink(pairing: Pairing, name = hostname()): string {
  // encodeURIComponent, not URLSearchParams: iOS URLComponents does not read `+` as a space.
  const query = Object.entries({ v: '1', r: pairing.relay, i: pairing.roomId, k: pairing.secret, n: name })
    .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
    .join('&')
  return `dshduo://pair?${query}`
}

/** The pairing QR as a standalone SVG, for the in-app iPhone page. */
export async function pairingSvg(link: string): Promise<string> {
  return await QRCode.toString(link, { type: 'svg', errorCorrectionLevel: 'M', margin: 1, color: { dark: '#000000', light: '#ffffff' } })
}

/** A QR code drawn with half-block characters, readable from a terminal or a monospace chat block. */
export async function pairingQr(link: string): Promise<string> {
  return await QRCode.toString(link, { type: 'utf8', errorCorrectionLevel: 'M', margin: 2 })
}

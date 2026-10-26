/**
 * dsh-plugin-duo-remote: lets the DSH Duo iPhone app drive this dsh from
 * anywhere. The plugin dials out to a relay, so the machine needs no open
 * port, VPN, or public address; every message is end-to-end encrypted.
 */

import { execFileSync } from 'node:child_process'
import { hostname } from 'node:os'
import { Bridge, VERSION } from './bridge.ts'
import type { HostContext, Logger } from './host.ts'
import type { ApnsTransport } from './push.ts'
import { dshHome } from './pairing.ts'
import { providePanel } from './panel.ts'

/** Public relay used when neither the plugin row nor `$DSH_DUO_RELAY` names one. It only ever sees ciphertext. */
export const DEFAULT_RELAY = 'https://dsh-duo-relay.cloudflare-hybrid809.workers.dev'

export const name = 'duo-remote'
export const inject = ['typertGateway', 'connection']

export interface Config {
  /** Relay base URL. Falls back to `$DSH_DUO_RELAY`, then the public {@link DEFAULT_RELAY}. */
  relay?: string
  /** Name the phone shows for this machine; defaults to the host name. */
  hostName?: string
  /** Keep DeepSeek's questions waiting for the phone when no Web client answers. Default true. */
  holdQuestions?: boolean
  /** Messages loaded when a Session opens. Default 200. */
  historyMessages?: number
  /** Test hook: replaces the HTTP/2 connection to Apple. */
  apnsTransport?: ApnsTransport
}

function loggerOf(ctx: HostContext): { info(message: string): void; warn(message: string): void } {
  const raw = ctx.logger
  const logger: Logger = typeof raw === 'function' ? raw('duo-remote') : raw ?? console
  return {
    info: message => logger.info(message),
    warn: message => logger.warn(message),
  }
}

/** The Mac's user-facing name ("Evan's MacBook Pro"), falling back to the network host name. */
function computerName(): string {
  if (process.platform === 'darwin') {
    try {
      const name = execFileSync('scutil', ['--get', 'ComputerName'], { encoding: 'utf8', timeout: 2000 }).trim()
      if (name !== '') return name
    } catch { /* fall back */ }
  }
  return hostname().replace(/\.local$/, '')
}

export function apply(ctx: HostContext, config: Config = {}): void {
  const log = loggerOf(ctx)
  const relay = config.relay || process.env.DSH_DUO_RELAY || DEFAULT_RELAY
  const home = dshHome(ctx.get('profileContext')?.home)
  const bridge = new Bridge(ctx, {
    relay,
    home,
    hostName: config.hostName ?? computerName(),
    holdQuestions: config.holdQuestions ?? true,
    historyMessages: config.historyMessages ?? 200,
    ...config.apnsTransport === undefined ? {} : { apnsTransport: config.apnsTransport },
  }, log)

  const started = bridge.start().then(() => bridge, (error: unknown) => {
    log.warn(`duo-remote failed to start: ${String(error)}`)
    throw error
  })
  started.catch(() => undefined)

  // The "iPhone" page in the dsh Web and Desktop apps; absent on headless profiles.
  const unprovide = providePanel(ctx, started)

  const unregister = ctx.get('commands')?.register({
    name: 'duo-pair',
    description: 'DSH Duo (iPhone) connection status',
    handler: async () => {
      await started
      // The pairing code carries the room secret, so it is shown only on the iPhone page, never in a Session log.
      return { kind: 'success', text: `DSH Duo ${VERSION}\n${bridge.status()}\n\nTo pair an iPhone, open **iPhone** in the sidebar.` }
    },
  })

  const dispose = (): void => {
    unregister?.()
    unprovide?.()
    void bridge.stop()
  }
  if (typeof ctx.effect === 'function') ctx.effect(() => dispose)
  else ctx.on('dispose', dispose)
}

export { pairingLink, pairingQr } from './pairing.ts'

/**
 * dsh-plugin-duo-remote: lets the DSH Duo iPhone app drive this dsh from
 * anywhere. The plugin dials out to a relay, so the machine needs no open
 * port, VPN, or public address; every message is end-to-end encrypted.
 */

import { hostname } from 'node:os'
import { Bridge, VERSION } from './bridge.ts'
import type { HostContext, Logger } from './host.ts'
import type { ApnsTransport } from './push.ts'
import { dshHome, pairingLink, pairingPath, pairingQr, rotatePairing } from './pairing.ts'

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

export function apply(ctx: HostContext, config: Config = {}): void {
  const log = loggerOf(ctx)
  const relay = config.relay || process.env.DSH_DUO_RELAY || DEFAULT_RELAY
  const home = dshHome(ctx.get('profileContext')?.home)
  const bridge = new Bridge(ctx, {
    relay,
    home,
    hostName: config.hostName ?? hostname(),
    holdQuestions: config.holdQuestions ?? true,
    historyMessages: config.historyMessages ?? 200,
    ...config.apnsTransport === undefined ? {} : { apnsTransport: config.apnsTransport },
  }, log)

  const started = bridge.start().catch((error: unknown) => {
    log.warn(`duo-remote failed to start: ${String(error)}`)
  })

  const unregister = ctx.get('commands')?.register({
    name: 'duo-pair',
    description: 'Show DSH Duo (iPhone) pairing status; `/duo-pair qr` prints the pairing QR in the dsh terminal',
    input: { hint: 'qr | rotate' },
    handler: async ({ rawInput }) => {
      await started
      const arg = rawInput.trim()
      if (arg === 'rotate') {
        const pairing = await rotatePairing(pairingPath(home), relay)
        process.stdout.write(`\n${await pairingQr(pairingLink(pairing, config.hostName ?? hostname()))}\n`)
        return { kind: 'success', text: 'Pairing rotated: every phone is unpaired. Restart dsh, then scan the new QR printed in its terminal (or run `dsh-duo pair`).' }
      }
      if (arg === 'qr') {
        await bridge.printPairing()
        return { kind: 'success', text: 'The pairing QR was printed in the terminal running dsh. You can also run `dsh-duo pair` in any terminal on this machine.' }
      }
      // The QR carries the room secret, so it is never written into the Session log.
      return { kind: 'success', text: `DSH Duo ${VERSION}\n${bridge.status()}\n\nRun \`/duo-pair qr\` or \`dsh-duo pair\` to show the pairing QR.` }
    },
  })

  const dispose = (): void => {
    unregister?.()
    void bridge.stop()
  }
  if (typeof ctx.effect === 'function') ctx.effect(() => dispose)
  else ctx.on('dispose', dispose)
}

export { pairingLink, pairingQr } from './pairing.ts'

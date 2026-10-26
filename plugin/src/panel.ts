/**
 * Remote API behind the "iPhone" page in the dsh Web and Desktop apps.
 *
 * Third-party bundles have no Typert build step, so this hand-writes what the
 * generator would emit: a Cordis service with a `typertRemote` binding plus a
 * strict manifest the API Gateway dispatches from. The browser half
 * (`client/client.js`) mounts the matching contribution.
 */

import type { Bridge } from './bridge.ts'
import type { HostContext } from './host.ts'

export const NAMESPACE = 'duoRemote'
const PACKAGE = 'dsh-plugin-duo-remote'

/** A strict codec whose parser only checks the outer shape; the methods own their inputs. */
function codec(type: string, check: (value: unknown) => boolean = () => true) {
  const schema = {
    parse(value: unknown): unknown {
      if (!check(value)) throw new TypeError(`${PACKAGE}: invalid ${type}`)
      return value
    },
  }
  // `schema` serves older harness builds, `create` newer ones; both read only these two.
  return { mode: 'strict' as const, typeSymbol: `${PACKAGE}#${type}`, schema, create: () => schema }
}

const isObject = (value: unknown): boolean => typeof value === 'object' && value !== null

function invocation(method: string, result: ReturnType<typeof codec>) {
  return {
    id: `${PACKAGE}#${NAMESPACE}/${method}`,
    service: NAMESPACE,
    namespace: NAMESPACE,
    method,
    invocation: { kind: 'direct' as const },
    parameters: [],
    result,
  }
}

export const MANIFEST = {
  package: PACKAGE,
  face: 'host' as const,
  schemas: [],
  invocations: [
    invocation('overview', codec('Overview', isObject)),
    invocation('pairingCode', codec('PairingCode', isObject)),
    invocation('unpairAll', codec('Overview', isObject)),
  ],
  model: { services: [], events: [], objects: [] },
}

interface TypertRegistry {
  register(manifest: typeof MANIFEST): () => void
}

/**
 * Provide the `duoRemote` service and its manifest for the life of the plugin.
 * @returns a disposer, or undefined on a Host without the Typert registry (headless).
 */
export function providePanel(ctx: HostContext, bridge: Promise<Bridge>): (() => void) | undefined {
  const typert = ctx.get('typert') as unknown as TypertRegistry | undefined
  if (typert === undefined || typeof typert.register !== 'function' || typeof ctx.provide !== 'function') return undefined

  const service = {
    async overview() {
      return (await bridge).overview()
    },
    async pairingCode() {
      return await (await bridge).pairingCode()
    },
    async unpairAll() {
      const ready = await bridge
      await ready.unpairAll()
      return ready.overview()
    },
  }
  Object.defineProperty(service, 'typertRemote', {
    value: Object.freeze({ service, serviceKey: NAMESPACE, namespace: NAMESPACE }),
    enumerable: false,
  })
  const unprovide = ctx.provide(NAMESPACE, service)
  const unregister = typert.register(MANIFEST)
  return () => {
    unregister()
    unprovide()
  }
}

/**
 * Calls dsh Remote methods in-process through the Typert Gateway, speaking
 * for one owner Peer. This is the same API the dsh Web client uses over HTTP,
 * so the phone gets exactly the Web client's capabilities and validation.
 */

import type { HostContext, PeerScope } from './host.ts'

/**
 * Wire field names by position, used only when the Host runs from source and
 * publishes no strict descriptor. Strict builds read names from `ctx.typert`.
 */
const FALLBACK_WIRE: Record<string, readonly string[]> = {
  'session/list': ['_request'],
  'session/create': ['request'],
  'session/selectModel': ['request'],
  'session/modelCatalog': [],
  'session/rename': ['request'],
  'session/prompt': ['request'],
  'session/cancel': ['request'],
  'session/follow': ['request'],
  'session/control': [],
  'agentPresets/list': [],
  'agentPresets/select': ['agentId', 'agentPreset'],
  'commands/list': ['agentId'],
  'commands/execute': ['agentId', 'line', 'submittedAttachments'],
  'skills/list': ['request'],
  'workspace/create': ['request'],
  'workspace/follow': [],
  'directoryPicker/list': ['path'],
  'userQuestions/answer': ['agentId', 'callId', 'answer'],
}

export class RemoteFailure extends Error {
  readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.code = code
  }
}

/** Normalize anything a Remote method threw into `{ code, message }`. */
export function failureOf(error: unknown): RemoteFailure {
  if (error instanceof RemoteFailure) return error
  const record = typeof error === 'object' && error !== null ? error as { code?: unknown; message?: unknown } : {}
  const code = typeof record.code === 'string' ? record.code : 'host/internal'
  const message = typeof record.message === 'string' ? record.message : String(error)
  return new RemoteFailure(code, message)
}

export class Remote {
  private readonly ctx: HostContext
  readonly peer: PeerScope

  constructor(ctx: HostContext) {
    this.ctx = ctx
    this.peer = ctx.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'none' })
  }

  private request(endpoint: string, positional: readonly unknown[], signal?: AbortSignal) {
    const slash = endpoint.indexOf('/')
    const descriptor = this.ctx.get('typert')?.local?.get(endpoint)
    const names = descriptor?.parameters.map(parameter => parameter.wire) ?? FALLBACK_WIRE[endpoint]
    if (names === undefined) throw new RemoteFailure('host/unknown-endpoint', `unknown endpoint ${endpoint}`)
    const args = Object.fromEntries(names.map((name, index) => [name, positional[index]]))
    return {
      namespace: endpoint.slice(0, slash),
      method: endpoint.slice(slash + 1),
      args,
      peer: this.peer,
      ...signal === undefined ? {} : { signal },
    }
  }

  async call<T>(endpoint: string, ...positional: unknown[]): Promise<T> {
    try {
      return await this.ctx.typertGateway.invoke(this.request(endpoint, positional)) as T
    } catch (error) {
      throw failureOf(error)
    }
  }

  async stream<T>(endpoint: string, signal: AbortSignal, ...positional: unknown[]): Promise<AsyncIterable<T>> {
    try {
      return await this.ctx.typertGateway.stream(this.request(endpoint, positional, signal)) as AsyncIterable<T>
    } catch (error) {
      throw failureOf(error)
    }
  }

  async dispose(): Promise<void> {
    await this.peer.dispose()
  }
}

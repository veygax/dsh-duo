/**
 * The narrow slice of the dsh Host this plugin touches, declared locally so
 * the package builds without the dsh workspace. Every name here is a public
 * dsh service: `typertGateway` and `connection` (inject), `typert`,
 * `commands`, `profileContext` (optional).
 */

export interface PeerScope {
  readonly id: string
  readonly signal: AbortSignal
  dispose(): Promise<void>
}

export interface InvokeRemoteRequest {
  readonly namespace: string
  readonly method: string
  readonly args: Readonly<Record<string, unknown>>
  readonly peer: PeerScope
  readonly signal?: AbortSignal
}

export interface TypertGateway {
  invoke(request: InvokeRemoteRequest): Promise<unknown>
  stream(request: InvokeRemoteRequest): Promise<AsyncIterable<unknown>>
}

export interface Connection {
  createPeer(options: { readonly principal: { readonly kind: 'owner' }; readonly interactions?: 'answer' | 'none' }): PeerScope
}

export interface InvocationDescriptor {
  readonly parameters: readonly { readonly name: string; readonly wire: string }[]
}

export interface TypertRegistry {
  readonly local?: { get(endpoint: string): InvocationDescriptor | undefined }
}

export interface CommandResult {
  readonly kind: 'success' | 'error'
  readonly text?: string
}

export interface Commands {
  register(definition: {
    readonly name: string
    readonly description: string
    readonly input?: { readonly hint?: string }
    readonly handler: (invocation: { readonly rawInput: string }) => CommandResult | Promise<CommandResult>
  }): () => void
}

export interface Logger {
  info(...args: unknown[]): void
  warn(...args: unknown[]): void
  error?(...args: unknown[]): void
  debug?(...args: unknown[]): void
}

export interface AskUserQuestionItem {
  id: string
  question: string
  detail?: string
  header?: string
  options?: { label: string; description?: string }[]
  multiSelect?: boolean
  intent?: { kind: string; approve?: string; reject?: string; always?: string }
}

export interface AskUserQuestionAnswer {
  answers: { id: string; selected: string[]; custom?: string }[]
}

export interface AskUserQuestionRequestEvent {
  questions: AskUserQuestionItem[]
  agent?: { readonly id: string; readonly session: { readonly id: string } }
  signal?: AbortSignal
  wait?: { callId: string; timed?: boolean }
}

/** Host Context as this plugin uses it. */
export interface HostContext {
  readonly typertGateway: TypertGateway
  readonly connection: Connection
  readonly logger?: Logger | ((name: string) => Logger)
  get(name: 'typert'): TypertRegistry | undefined
  get(name: 'commands'): Commands | undefined
  get(name: 'profileContext'): { readonly home: string } | undefined
  get(name: string): unknown
  on(event: string, listener: (...args: never[]) => unknown, options?: { prepend?: boolean }): () => void
  effect?(execute: () => () => unknown): unknown
  /** Register a service owned by this plugin's fiber; returns its disposer. */
  provide?(name: string, value: object): () => void
}

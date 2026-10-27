/**
 * Projects the dsh Session log onto the small, stable item vocabulary the
 * phone renders (docs/PROTOCOL.md §4). The phone never sees dsh internals, so
 * dsh can evolve its log format behind this one file.
 */

export type Item =
  | { id: string; kind: 'user'; text: string; time: number; images?: number }
  | { id: string; kind: 'thinking'; text: string; time: number; turn: number }
  | { id: string; kind: 'text'; text: string; time: number; turn: number }
  | {
    id: string
    kind: 'tool'
    callId: string
    name: string
    args: string
    time: number
    turn: number
    status: 'running' | 'ok' | 'error'
    result?: string
  }
  | { id: string; kind: 'notice'; text: string; time: number; level: 'info' | 'error' }
  | { id: string; kind: 'turn'; time: number; turn: number; reason: string }

/** One durable event as the Session Remote delivers it. */
export interface WireEvent {
  readonly type: string
  readonly seq: number
  readonly time: number
  readonly data: unknown
}

const MAX_RESULT = 16_000
const MAX_ARGS = 16_000

type Json = Record<string, unknown>

function obj(value: unknown): Json | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? value as Json : undefined
}

function arr(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function clip(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max)}\n… (${text.length - max} more characters)`
}

/** Plain text of a content block list; images and files become short placeholders. */
export function blocksText(content: unknown): { text: string; images: number } {
  let images = 0
  const parts: string[] = []
  for (const raw of arr(content)) {
    const block = obj(raw)
    if (block === undefined) continue
    switch (block.type) {
      case 'text':
        if (typeof block.text === 'string') parts.push(block.text)
        break
      case 'image':
        images++
        break
      case 'file':
        parts.push(`[file ${typeof block.name === 'string' ? block.name : 'attachment'}]`)
        break
      default:
    }
  }
  return { text: parts.join('\n').trim(), images }
}

/** Human-authored prompt sources; injected context and goal rounds stay hidden. */
const HUMAN_SOURCES = new Set(['user', 'user-rpc', 'user-question-reply'])

/**
 * Incremental transcript for one Session. `apply` returns the items that were
 * added or changed so the caller can forward only the delta.
 */
export class Transcript {
  readonly items = new Map<string, Item>()
  title: string | undefined
  private readonly toolTurn = new Map<string, number>()
  /** Log position of each item's first appearance: seq * 1000 + block index. */
  private readonly order = new Map<string, number>()
  private last = 0

  private place(id: string, position: number): void {
    if (this.order.has(id)) return
    this.order.set(id, position)
    this.last = Math.max(this.last, position)
  }

  /** Insert an item that has no log position (a Host error, say) after everything so far. */
  add(item: Item): void {
    this.place(item.id, this.last + 1)
    this.items.set(item.id, item)
  }

  clear(): void {
    this.items.clear()
    this.order.clear()
    this.last = 0
  }

  apply(event: WireEvent): Item[] {
    const data = obj(event.data) ?? {}
    const changed: Item[] = []
    let block = 0
    const put = (item: Item): void => {
      this.place(item.id, event.seq * 1000 + block)
      this.items.set(item.id, item)
      changed.push(item)
    }
    const turn = typeof data.turn === 'number' ? data.turn : 0

    switch (event.type) {
      case 'user/message': {
        const message = obj(data.message) ?? data
        const source = obj(message.source)
        const kind = typeof source?.kind === 'string' ? source.kind : 'user'
        if (!HUMAN_SOURCES.has(kind) && kind !== 'user') break
        const { text, images } = blocksText(message.content)
        if (text === '' && images === 0) break
        if (kind === 'user-question-reply') {
          put({ id: `u${event.seq}`, kind: 'notice', text: `Answered: ${clip(text, 400)}`, time: event.time, level: 'info' })
        } else {
          put({ id: `u${event.seq}`, kind: 'user', text, time: event.time, ...images > 0 ? { images } : {} })
        }
        break
      }
      case 'assistant/message': {
        const message = obj(data.message)
        for (const raw of arr(message?.content)) {
          const content = obj(raw)
          const id = `a${event.seq}.${block}`
          if (content?.type === 'reasoning' && typeof content.text === 'string' && content.text.trim() !== '') {
            put({ id, kind: 'thinking', text: content.text, time: event.time, turn })
          } else if (content?.type === 'text' && typeof content.text === 'string' && content.text.trim() !== '') {
            put({ id, kind: 'text', text: content.text, time: event.time, turn })
          } else if (content?.type === 'tool-call' && typeof content.id === 'string') {
            this.place(`c${content.id}`, event.seq * 1000 + block)
            changed.push(...this.call(content.id, String(content.name ?? 'tool'), String(content.arguments ?? ''), event.time, turn))
          }
          block++
        }
        if (data.interrupted === true) {
          put({ id: `a${event.seq}.x`, kind: 'notice', text: 'Interrupted', time: event.time, level: 'info' })
        }
        break
      }
      case 'tool/call':
        if (typeof data.callId === 'string') {
          this.place(`c${data.callId}`, event.seq * 1000)
          changed.push(...this.call(data.callId, String(data.name ?? 'tool'), String(data.arguments ?? ''), event.time, turn))
        }
        break
      case 'tool/result': {
        const message = obj(data.message)
        const callId = typeof message?.toolCallId === 'string' ? message.toolCallId : undefined
        if (callId === undefined) break
        const existing = this.items.get(`c${callId}`)
        const failed = message?.isError === true
        const error = obj(data.error)
        const text = blocksText(message?.content).text
        const result = clip(failed && typeof error?.reason === 'string' ? `${error.reason}\n${text}`.trim() : text, MAX_RESULT)
        this.place(`c${callId}`, event.seq * 1000)
        const base = existing?.kind === 'tool'
          ? existing
          : { id: `c${callId}`, kind: 'tool' as const, callId, name: 'tool', args: '', time: event.time, turn: this.toolTurn.get(callId) ?? turn }
        put({ ...base, status: failed ? 'error' : 'ok', result })
        break
      }
      case 'turn/end': {
        const reason = obj(data.reason)
        put({ id: `t${event.seq}`, kind: 'turn', time: event.time, turn, reason: typeof reason?.kind === 'string' ? reason.kind : 'completed' })
        break
      }
      case 'command/run':
        if (typeof data.name === 'string') {
          const args = typeof data.args === 'string' && data.args.trim() !== '' ? ` ${data.args.trim()}` : ''
          put({ id: `k${String(data.commandId)}`, kind: 'user', text: `/${data.name}${args}`, time: event.time })
        }
        break
      case 'command/done':
        if (typeof data.text === 'string' && data.text.trim() !== '') {
          put({
            id: `k${String(data.commandId)}.done`,
            kind: 'notice',
            text: clip(data.text, MAX_RESULT),
            time: event.time,
            level: data.kind === 'error' ? 'error' : 'info',
          })
        }
        break
      case 'session/title':
        if (typeof data.title === 'string') this.title = data.title
        break
      default:
    }
    return changed
  }

  private call(callId: string, name: string, args: string, time: number, turn: number): Item[] {
    this.toolTurn.set(callId, turn)
    const existing = this.items.get(`c${callId}`)
    if (existing?.kind === 'tool' && existing.name === name && existing.args !== '') return []
    const item: Item = {
      id: `c${callId}`,
      kind: 'tool',
      callId,
      name,
      args: clip(args, MAX_ARGS),
      time,
      turn,
      status: existing?.kind === 'tool' ? existing.status : 'running',
      ...existing?.kind === 'tool' && existing.result !== undefined ? { result: existing.result } : {},
    }
    this.items.set(item.id, item)
    return [item]
  }

  /** Items in display order. */
  ordered(): Item[] {
    return [...this.items.values()].sort((a, b) => (this.order.get(a.id) ?? 0) - (this.order.get(b.id) ?? 0))
  }

  /** The most recent assistant reply, for notifications. */
  lastReply(): string | undefined {
    const item = this.lastReplyItem()
    return item?.kind === 'text' ? item.text : undefined
  }

  /** The final reply of the latest Turn, which a notification about it opens to. */
  lastReplyItem(): Item | undefined {
    const items = this.ordered()
    for (let index = items.length - 1; index >= 0; index--) {
      const item = items[index]!
      if (item.kind === 'text') return item
      if (item.kind === 'user') return undefined
    }
    return undefined
  }
}

/** One streaming assistant attempt that has not committed yet. */
export interface LiveAttempt {
  attemptId: string
  thinking: string
  text: string
  tools: { id: string; name: string; args: string }[]
}

/** Delta sent to the phone for one live attempt. */
export interface LiveDelta {
  attemptId: string
  reset?: true
  thinking?: string
  text?: string
  tools?: { id: string; name: string; args: string }[]
}

/**
 * Folds `assistant-stream` frames (live `StreamChunk`s or compact
 * `AssistantStreamRecord`s from a reconnect baseline) into a LiveAttempt.
 */
export class LiveReducer {
  attempt: LiveAttempt | undefined
  private pending: LiveDelta | undefined

  start(attemptId: string): void {
    this.attempt = { attemptId, thinking: '', text: '', tools: [] }
    this.pending = { attemptId, reset: true }
  }

  end(): void {
    this.attempt = undefined
    this.pending = undefined
  }

  /** Accepts either a raw StreamChunk or a compact stream record. */
  chunk(raw: unknown): void {
    const attempt = this.attempt
    const chunk = obj(raw)
    if (attempt === undefined || chunk === undefined) return
    switch (chunk.type) {
      case 'text-delta':
        if (typeof chunk.text === 'string') this.addText('text', chunk.text)
        return
      case 'reasoning-delta':
        if (typeof chunk.text === 'string') this.addText('thinking', chunk.text)
        return
      case 'text-chunks':
        this.addText('text', arr(chunk.texts).filter(text => typeof text === 'string').join(''))
        return
      case 'reasoning-chunks':
        this.addText('thinking', arr(chunk.texts).filter(text => typeof text === 'string').join(''))
        return
      case 'tool-call-delta':
        this.addTool(String(chunk.id), typeof chunk.name === 'string' ? chunk.name : undefined,
          typeof chunk.argumentsDelta === 'string' ? chunk.argumentsDelta : '')
        return
      case 'tool-call-chunks':
        this.addTool(String(chunk.id), typeof chunk.name === 'string' ? chunk.name : undefined,
          arr(chunk.args).filter(text => typeof text === 'string').join(''))
        return
      case 'chunk':
        this.chunk(chunk.chunk)
        return
      default:
    }
  }

  /** Take the accumulated delta since the last flush. */
  flush(): LiveDelta | undefined {
    const delta = this.pending
    this.pending = undefined
    return delta
  }

  private delta(): LiveDelta {
    this.pending ??= { attemptId: this.attempt!.attemptId }
    return this.pending
  }

  private addText(field: 'thinking' | 'text', text: string): void {
    if (text === '') return
    this.attempt![field] += text
    const delta = this.delta()
    delta[field] = (delta[field] ?? '') + text
  }

  private addTool(id: string, name: string | undefined, args: string): void {
    const tools = this.attempt!.tools
    let tool = tools.find(item => item.id === id)
    if (tool === undefined) {
      tool = { id, name: name ?? 'tool', args: '' }
      tools.push(tool)
    }
    if (name !== undefined) tool.name = name
    tool.args = clip(tool.args + args, 2_000)
    this.delta().tools = tools.map(item => ({ ...item }))
  }
}

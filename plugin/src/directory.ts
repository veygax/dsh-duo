/**
 * Live, merged view of Sessions and Workspaces for the phone's sidebar. Fed by
 * `session/list`, the `session/control` projection stream, the
 * `workspace/follow` stream, and the Host's `api-session/*` events.
 */

import type { Remote } from './remote.ts'

export interface ModelRef {
  provider: string
  model: string
  effort?: string
}

export interface QuestionView {
  callId: string
  state: 'open' | 'continued'
  questions: {
    id: string
    question: string
    header?: string
    detail?: string
    options: { label: string; description?: string }[]
    multiSelect: boolean
    intent?: string
  }[]
}

export interface SessionView {
  id: string
  title: string
  updatedAt: number
  running: boolean
  blank: boolean
  cwd?: string
  workspaceId?: string
  preset?: string
  model?: ModelRef
  questions: number
  parentId?: string
}

export interface WorkspaceView {
  id: string
  title: string
  path: string
  sessionIds: string[]
}

type Json = Record<string, unknown>

function obj(value: unknown): Json | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? value as Json : undefined
}

function modelOf(value: unknown): ModelRef | undefined {
  const projection = obj(value)
  const selection = obj(projection?.next) ?? obj(projection?.lastUsed)
  if (typeof selection?.provider !== 'string' || typeof selection.model !== 'string') return undefined
  return {
    provider: selection.provider,
    model: selection.model,
    ...typeof selection.reasoningEffort === 'string' ? { effort: selection.reasoningEffort } : {},
  }
}

export function questionsOf(value: unknown): QuestionView[] {
  const projection = obj(value)
  if (!Array.isArray(projection?.active)) return []
  return projection.active.flatMap((raw): QuestionView[] => {
    const pending = obj(raw)
    if (typeof pending?.callId !== 'string' || !Array.isArray(pending.questions)) return []
    return [{
      callId: pending.callId,
      state: pending.state === 'continued' ? 'continued' : 'open',
      questions: pending.questions.flatMap((item) => {
        const question = obj(item)
        if (typeof question?.id !== 'string' || typeof question.question !== 'string') return []
        return [{
          id: question.id,
          question: question.question,
          ...typeof question.header === 'string' ? { header: question.header } : {},
          ...typeof question.detail === 'string' ? { detail: question.detail } : {},
          options: Array.isArray(question.options)
            ? question.options.flatMap((option) => {
              const row = obj(option)
              return typeof row?.label === 'string'
                ? [{ label: row.label, ...typeof row.description === 'string' ? { description: row.description } : {} }]
                : []
            })
            : [],
          multiSelect: question.multiSelect === true,
          ...typeof obj(question.intent)?.kind === 'string' ? { intent: obj(question.intent)!.kind as string } : {},
        }]
      }),
    }]
  })
}

interface Entry {
  summary: Json
  values: Json
}

export interface DirectoryEvents {
  upsert(session: SessionView): void
  remove(sessionId: string): void
  workspaces(workspaces: WorkspaceView[]): void
  questions(sessionId: string, questions: QuestionView[]): void
}

export class Directory {
  private readonly entries = new Map<string, Entry>()
  private workspaceList: WorkspaceView[] = []
  private readonly workspaceOf = new Map<string, string>()
  private archived = new Set<string>()
  private readonly dirty = new Set<string>()
  private flushTimer: ReturnType<typeof setTimeout> | undefined
  private loaded: Promise<void> | undefined
  private readonly remote: Remote
  private readonly events: DirectoryEvents
  private readonly signal: AbortSignal
  private readonly warn: (message: string) => void

  constructor(remote: Remote, events: DirectoryEvents, signal: AbortSignal, warn: (message: string) => void) {
    this.remote = remote
    this.events = events
    this.signal = signal
    this.warn = warn
  }

  /** Load the initial list once and keep the two streams running until `signal` aborts. */
  ready(): Promise<void> {
    this.loaded ??= this.start()
    return this.loaded
  }

  private async start(): Promise<void> {
    await this.refresh()
    void this.follow('session/control', frame => this.onControl(frame))
    void this.follow('workspace/follow', frame => this.onWorkspace(frame))
  }

  async refresh(): Promise<void> {
    const value = await this.remote.call<{ items: Json[] }>('session/list', {})
    for (const summary of value.items) this.upsertSummary(summary, false)
  }

  /** Keep one stream alive with backoff; each generation begins with a baseline. */
  private async follow(endpoint: string, onFrame: (frame: Json) => void): Promise<void> {
    let attempt = 0
    while (!this.signal.aborted) {
      try {
        const stream = await this.remote.stream<Json>(endpoint, this.signal)
        for await (const frame of stream) {
          attempt = 0
          onFrame(frame)
        }
      } catch (error) {
        if (this.signal.aborted) return
        this.warn(`duo: ${endpoint} stream ended: ${String((error as Error).message ?? error)}`)
      }
      const delay = Math.min(30_000, 500 * 2 ** attempt++)
      await new Promise(resolve => setTimeout(resolve, delay).unref?.())
    }
  }

  private onControl(frame: Json): void {
    if (frame.type === 'baseline') {
      const projections = obj(obj(frame.value)?.projections) ?? {}
      for (const [sessionId, baseline] of Object.entries(projections)) {
        this.patch(sessionId, obj(obj(baseline)?.values) ?? {})
      }
    } else if (frame.type === 'projection' && typeof frame.sessionId === 'string' && typeof frame.key === 'string') {
      this.patch(frame.sessionId, { [frame.key]: frame.value })
    }
  }

  private onWorkspace(frame: Json): void {
    const apply = (value: Json): void => {
      this.workspaceList = Array.isArray(value.items) ? value.items.flatMap(item => this.workspaceView(item)) : []
      this.archived = new Set(Array.isArray(value.archivedSessionIds) ? value.archivedSessionIds as string[] : [])
    }
    switch (frame.type) {
      case 'baseline':
      case 'replace':
        apply(obj(frame.value) ?? {})
        break
      case 'upsert': {
        const [view] = this.workspaceView(frame.workspace)
        if (view === undefined) break
        const index = this.workspaceList.findIndex(item => item.id === view.id)
        if (index === -1) this.workspaceList.push(view)
        else this.workspaceList[index] = view
        break
      }
      case 'remove':
        this.workspaceList = this.workspaceList.filter(item => item.id !== frame.workspaceId)
        break
      case 'order':
        if (Array.isArray(frame.workspaceIds)) {
          const order = frame.workspaceIds as string[]
          this.workspaceList.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id))
        }
        break
      case 'archived':
        if (Array.isArray(frame.archivedSessionIds)) {
          const before = this.archived
          this.archived = new Set(frame.archivedSessionIds as string[])
          for (const id of before) if (!this.archived.has(id)) this.markDirty(id)
          for (const id of this.archived) if (!before.has(id)) this.events.remove(id)
        }
        break
      default:
    }
    this.workspaceOf.clear()
    for (const workspace of this.workspaceList) for (const id of workspace.sessionIds) this.workspaceOf.set(id, workspace.id)
    for (const id of this.entries.keys()) this.markDirty(id)
    this.events.workspaces(this.workspaces())
  }

  private workspaceView(raw: unknown): WorkspaceView[] {
    const item = obj(raw)
    if (typeof item?.workspaceId !== 'string' || typeof item.path !== 'string') return []
    return [{
      id: item.workspaceId,
      title: typeof item.title === 'string' && item.title !== '' ? item.title : item.path.split('/').pop() ?? item.path,
      path: item.path,
      sessionIds: Array.isArray(item.sessionIds) ? item.sessionIds.filter(id => typeof id === 'string') : [],
    }]
  }

  /** Apply an `api-session/added` summary or a `session/list` row. */
  upsertSummary(summary: Json, notify = true): void {
    if (typeof summary.sessionId !== 'string') return
    const entry = this.entries.get(summary.sessionId)
    const hinted = obj(obj(summary.projections)?.values) ?? {}
    if (entry === undefined) {
      this.entries.set(summary.sessionId, { summary, values: hinted })
    } else {
      entry.summary = { ...entry.summary, ...summary }
      entry.values = { ...hinted, ...entry.values }
    }
    if (notify) this.markDirty(summary.sessionId)
  }

  status(sessionId: string, running: boolean): boolean {
    const entry = this.entries.get(sessionId)
    if (entry === undefined) return false
    const was = entry.summary.running === true
    entry.summary = { ...entry.summary, running }
    this.markDirty(sessionId)
    return was && !running
  }

  activity(sessionId: string, updatedAt: number): void {
    const entry = this.entries.get(sessionId)
    if (entry === undefined) return
    entry.summary = { ...entry.summary, updatedAt, blank: false }
    this.markDirty(sessionId)
  }

  removed(sessionId: string): void {
    // A Session leaving the live registry is unloaded, not deleted; keep the row.
    const entry = this.entries.get(sessionId)
    if (entry === undefined) return
    entry.summary = { ...entry.summary, running: false, agentAvailable: false }
    this.markDirty(sessionId)
  }

  private patch(sessionId: string, values: Json): void {
    let entry = this.entries.get(sessionId)
    if (entry === undefined) {
      entry = { summary: { sessionId, updatedAt: Date.now(), running: false, blank: true }, values: {} }
      this.entries.set(sessionId, entry)
    }
    entry.values = { ...entry.values, ...values }
    if ('userQuestions' in values) this.events.questions(sessionId, questionsOf(values.userQuestions))
    this.markDirty(sessionId)
  }

  private markDirty(sessionId: string): void {
    this.dirty.add(sessionId)
    this.flushTimer ??= setTimeout(() => this.flush(), 200)
  }

  private flush(): void {
    this.flushTimer = undefined
    for (const id of this.dirty) {
      const view = this.view(id)
      if (view !== undefined) this.events.upsert(view)
    }
    this.dirty.clear()
  }

  view(sessionId: string): SessionView | undefined {
    const entry = this.entries.get(sessionId)
    if (entry === undefined || entry.summary.origin === 'subagent' || this.archived.has(sessionId)) return undefined
    const { summary, values } = entry
    const title = typeof values.title === 'string' && values.title.trim() !== '' ? values.title : undefined
    const cwd = typeof summary.cwd === 'string' ? summary.cwd
      : typeof values.workingDirectory === 'string' ? values.workingDirectory : undefined
    const model = modelOf(values.modelSelection)
    const blank = summary.blank === true
    return {
      id: sessionId,
      title: title ?? (blank ? 'New session' : 'Untitled session'),
      updatedAt: typeof summary.updatedAt === 'number' ? summary.updatedAt : 0,
      running: summary.running === true,
      blank,
      ...cwd === undefined ? {} : { cwd },
      ...this.workspaceOf.has(sessionId) ? { workspaceId: this.workspaceOf.get(sessionId)! } : {},
      ...typeof values.agentPreset === 'string' ? { preset: values.agentPreset } : {},
      ...model === undefined ? {} : { model },
      questions: questionsOf(values.userQuestions).length,
      ...typeof summary.parentSessionId === 'string' ? { parentId: summary.parentSessionId } : {},
    }
  }

  title(sessionId: string): string {
    return this.view(sessionId)?.title ?? 'Session'
  }

  pendingQuestions(sessionId: string): QuestionView[] {
    return questionsOf(this.entries.get(sessionId)?.values.userQuestions)
  }

  sessions(): SessionView[] {
    return [...this.entries.keys()]
      .flatMap(id => this.view(id) ?? [])
      .sort((a, b) => b.updatedAt - a.updatedAt)
  }

  workspaces(): WorkspaceView[] {
    return this.workspaceList.map(workspace => ({ ...workspace, sessionIds: [...workspace.sessionIds] }))
  }
}

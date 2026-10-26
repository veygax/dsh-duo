/** Phones that have joined this Host's room, for the pairing page. */

import { readFile, rename, writeFile } from 'node:fs/promises'

export interface PhoneRecord {
  name?: string
  model?: string
  readonly firstSeen: number
  lastSeen: number
}

export class Phones {
  private readonly path: string
  private records: Record<string, PhoneRecord> = {}
  private saving: Promise<void> = Promise.resolve()

  constructor(path: string) {
    this.path = path
  }

  async load(): Promise<void> {
    try {
      this.records = JSON.parse(await readFile(this.path, 'utf8')) as Record<string, PhoneRecord>
    } catch {
      this.records = {}
    }
  }

  entries(): [string, PhoneRecord][] {
    return Object.entries(this.records)
  }

  /** Record a sighting; `details` comes from the phone's sealed `hello`. */
  seen(id: string, details: { name?: string; model?: string } = {}): void {
    const now = Date.now()
    const record = this.records[id] ?? { firstSeen: now, lastSeen: now }
    record.lastSeen = now
    if (details.name !== undefined) record.name = details.name.slice(0, 80)
    if (details.model !== undefined) record.model = details.model.slice(0, 40)
    this.records[id] = record
    this.save()
  }

  clear(): void {
    this.records = {}
    this.save()
  }

  private save(): void {
    const snapshot = JSON.stringify(this.records, null, 2)
    this.saving = this.saving.then(async () => {
      const temp = `${this.path}.${process.pid}.tmp`
      await writeFile(temp, snapshot, { mode: 0o600 })
      await rename(temp, this.path)
    }).catch(() => undefined)
  }
}

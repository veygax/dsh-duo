/**
 * The first `session/list` races the Host activating the Session service that
 * answers it: this plugin applies first, and the Gateway rejects the call with
 * `gateway/service-unavailable` instead of queueing it. A rejection must be
 * retried, never cached for the rest of the process.
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Directory, type DirectoryEvents } from '../src/directory.ts'
import type { Remote } from '../src/remote.ts'

const unavailable = Object.assign(
  new Error('typert gateway: session/list: active Service "sessionController" is unavailable'),
  { code: 'gateway/service-unavailable' },
)

const row = {
  sessionId: 'sess-1',
  agentAvailable: true,
  updatedAt: 1000,
  running: false,
  blank: false,
  cwd: '/work/app',
  projections: { kind: 'sequenced', asOfSeq: 9, values: { title: 'Fix the login bug' } },
}

function events(): DirectoryEvents {
  return { upsert: () => {}, remove: () => {}, workspaces: () => {}, questions: () => {} }
}

/** A Remote whose first `failures` session lists reject, and whose streams idle until aborted. */
function fakeRemote(failures: number, signal: AbortSignal): { remote: Remote; calls: () => number } {
  let calls = 0
  const idle = {
    [Symbol.asyncIterator]: () => ({
      next: () => new Promise<IteratorResult<never>>((resolve) => {
        if (signal.aborted) resolve({ done: true, value: undefined })
        else signal.addEventListener('abort', () => resolve({ done: true, value: undefined }), { once: true })
      }),
    }),
  }
  const stub = {
    async call<T>(): Promise<T> {
      calls++
      if (calls <= failures) throw unavailable
      return { items: [row] } as T
    },
    async stream(): Promise<typeof idle> {
      return idle
    },
  }
  return { remote: stub as unknown as Remote, calls: () => calls }
}

test('the first session list survives the Host activation race', async () => {
  const controller = new AbortController()
  const { remote, calls } = fakeRemote(1, controller.signal)
  const directory = new Directory(remote, events(), controller.signal, () => {})

  await directory.ready()

  assert.equal(calls(), 2, 'the rejected list was retried once')
  assert.deepEqual(directory.sessions().map(session => session.title), ['Fix the login bug'])
  controller.abort()
})

test('a failure that outlasts the retry window is retried by the next request', async () => {
  const controller = new AbortController()
  // One initial attempt plus every retry fails; the eighth call is the next ready().
  const { remote, calls } = fakeRemote(7, controller.signal)
  const directory = new Directory(remote, events(), controller.signal, () => {})

  await assert.rejects(directory.ready(), /sessionController/)
  await directory.ready()

  assert.equal(calls(), 8)
  assert.deepEqual(directory.sessions().map(session => session.title), ['Fix the login bug'])
  controller.abort()
})

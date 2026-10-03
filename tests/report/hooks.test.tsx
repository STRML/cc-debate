import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { fingerprint } from '../../hooks/report/lib'
import { standIn } from '../seats/stand-in'
import { ROOT, archive, finding } from './fixtures'

const BAND = { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 100 } as never
const PANE = { title: 'Findings board', isFocused: true, bodyColumns: 100, placement: 'inline' } as never
const SCORE = { title: 'Seat scorecard', isFocused: true, bodyColumns: 100, placement: 'inline' } as never
const DIR = '/Users/x/.acpx/debate-reports'
const ARCHIVE_CALL = `bash ~/.claude/debate-scripts/seat-report.sh --archive "${ROOT}/.tmp/ai-review-ab12cd34/report.json" --round 1`
const KEY = `${fingerprint('src/a.ts', 'Reads before it writes')}#1`

type Disk = Record<string, { text: string; mtimeMs: number; size?: number }>
type Options = { cwd?: string; toplevel?: string | null; archiveFails?: boolean }

/** A machine with saved reports on disk, a git checkout at `toplevel`, and a session started in `cwd`. */
const world = (on: On, disk: Disk, { cwd = ROOT, toplevel = ROOT, archiveFails = false }: Options = {}) => {
  const clock = mock.clock(on, { now: new Date(2026, 9, 2, 15, 0, 0).getTime() })
  const sent: string[] = []
  const opened: string[] = []
  const runs: { argv: readonly string[]; cwd: string | undefined }[] = []
  const lists: string[] = []
  const reads: string[] = []
  // The plugin's store, kept here so a test can read what the board saved and seed what an earlier session left.
  const store: Record<string, unknown> = {}

  mock.env(on, { HOME: '/Users/x' })
  on('store.get', (_$, e) => ({ value: e.key in store ? JSON.parse(JSON.stringify(store[e.key])) : undefined }))
  on('store.set', (_$, e) => {
    store[e.key] = JSON.parse(JSON.stringify(e.value))

    return { value: undefined }
  })
  on('store.delete', (_$, e) => {
    delete store[e.key]

    return { value: undefined }
  })
  on('store.keys', () => ({ value: Object.keys(store) }))

  on('session.start', () => ({ cwd }))
  on('session.cwd', () => ({ value: cwd }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('ui.open', (_$, e) => {
    opened.push(e.id)

    return { value: { isPlaced: true } }
  })
  on('ui.close', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('prompt.submit', (_$, e) => {
    sent.push(e.text)

    return { text: e.text }
  })
  on('tool.call', () => (archiveFails ? { result: {}, text: 'exit 1', isError: true } : { result: {}, text: 'ok' }))
  on('process.run', (_$, e) => {
    runs.push({ argv: e.argv, cwd: e.init?.cwd })

    return {
      value: { exitCode: toplevel === null ? 128 : 0, stdout: toplevel === null ? '' : `${toplevel}\n`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine band</Text>
  })
  on('fs.list', (_$, e) => {
    lists.push(e.path)

    return e.path === DIR
      ? { value: Object.entries(disk).map(([name, file]) => ({ name, kind: 'file', size: file.size ?? file.text.length, mtimeMs: file.mtimeMs, isLink: false })) }
      : { deny: `ENOENT ${e.path}` }
  })
  on('fs.read', (_$, e) => {
    reads.push(e.path)

    const file = e.path.startsWith(`${DIR}/`) ? disk[e.path.slice(DIR.length + 1)] : undefined

    return file === undefined ? { deny: `ENOENT ${e.path}` } : { value: file.text }
  })

  // A button sends its prompt from a timer, outside the press, so tests let the timer fire.
  return { clock, sent, opened, runs, lists, reads, store, landed: () => clock.advance(100) }
}

const start = ($: any, cwd = ROOT) => $.session.start({ cwd, surface: 'terminal', isInteractive: true })
const band = ($: any) => $.ui.mount({ plugin: 'debate', surface: 'terminal', component: 'AbovePrompt', props: BAND })
const pane = ($: any) => $.ui.mount({ plugin: 'debate', surface: 'terminal', component: 'Pane', requestId: 'debate-board', props: PANE })
const scorePane = ($: any) => $.ui.mount({ plugin: 'debate', surface: 'terminal', component: 'Pane', requestId: 'debate-scorecard', props: SCORE })
const run = ($: any, command: string) =>
  $.command.run({ command, args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 120 } })
const reportWritten = ($: any) => $.tool.call({ tool: 'Bash', command: ARCHIVE_CALL })
const item = (key: string) => ({ key: `finding:${key}` })

const saved = (options: Parameters<typeof archive>[0] = {}, mtimeMs = 1000) => ({ text: archive(options), mtimeMs })

test('the root comes from git, so a session started in a subdirectory finds its panel', async ($, on) => {
  const w = world(on, { 'ab12cd34-r1.json': saved() }, { cwd: `${ROOT}/src/deep` })
  await start($, `${ROOT}/src/deep`)

  const reply = await run($, 'debate-board')

  expect(reply.text).toContain('1 open of 1')
  expect(w.runs[0]?.argv).toEqual(['git', 'rev-parse', '--show-toplevel'])
  expect(w.runs[0]?.cwd).toBe(`${ROOT}/src/deep`)
})

test('a linked worktree is its own root: its panel shows, the main checkout\'s does not', async ($, on) => {
  const worktree = `${ROOT}/.worktrees/t1`

  world(
    on,
    {
      'ab12cd34-r1.json': saved({ root: ROOT }, 2000),
      'cd34ef56-r1.json': saved({ id: 'cd34ef56', root: worktree, findings: [finding({ claim: 'Worktree finding' })] }, 1000),
    },
    { cwd: worktree, toplevel: worktree },
  )
  await start($, worktree)
  await run($, 'debate-board')

  const ui = await pane($)

  expect(await ui.find(item(`${fingerprint('src/a.ts', 'Worktree finding')}#1`))).toBeDefined()
  expect(await ui.find(item(KEY))).toBeUndefined()
})

test('the board ignores a newer report from another repo, and from a sibling folder with the same prefix', async ($, on) => {
  world(on, {
    'ab12cd34-r1.json': saved({}, 1000),
    'cd34ef56-r1.json': saved({ id: 'cd34ef56', root: '/Users/x/proj-evil', findings: [finding({ claim: 'Evil' })] }, 3000),
    'ef56ab78-r1.json': saved({ id: 'ef56ab78', root: '/Users/x/other', findings: [finding({ claim: 'Other' })] }, 2000),
  })
  await start($)
  await run($, 'debate-board')

  const ui = await pane($)

  expect(await ui.find(item(KEY))).toBeDefined()
  expect(await ui.find(item(`${fingerprint('src/a.ts', 'Evil')}#1`))).toBeUndefined()
  expect(await ui.find(item(`${fingerprint('src/a.ts', 'Other')}#1`))).toBeUndefined()
})

test('the folder handed to fs.list is absolute, since $.fs does not expand ~', async ($, on) => {
  const w = world(on, { 'ab12cd34-r1.json': saved() })
  await start($)
  await run($, 'debate-board')

  expect(w.lists.length).toBeGreaterThan(0)
  expect(w.lists.every(path => path.startsWith('/'))).toBe(true)
  expect(w.lists).toContain(DIR)
})

test('with no report for this root, the board says which root it looked for', async ($, on) => {
  world(on, {})
  await start($)

  expect((await run($, 'debate-board')).text).toContain(`No panel report for ${ROOT}`)
})

test('outside a git repository there is nothing to show, and it says so', async ($, on) => {
  world(on, { 'ab12cd34-r1.json': saved() }, { toplevel: null })
  await start($)

  expect((await run($, 'debate-board')).text).toContain('Not inside a git repository')
})

test('a saved file that cannot be read is reported, not drawn', async ($, on) => {
  world(on, { 'ab12cd34-r1.json': { text: 'garbage', mtimeMs: 1 } })
  await start($)

  expect((await run($, 'debate-board')).text).toContain('could not be read')
})

test('findings are grouped by severity, with the claim, the failure and the fix', async ($, on) => {
  world(on, {
    'ab12cd34-r1.json': saved({ findings: [finding({ severity: 'critical', claim: 'Crash' }), finding({ severity: 'minor', claim: 'Typo', file: 'src/b.ts' })] }),
  })
  await start($)
  await run($, 'debate-board')

  const ui = await pane($)

  expect(await ui.find({ key: 'group:critical' })).toBeDefined()
  expect(await ui.find({ key: 'group:minor' })).toBeDefined()
  expect(await ui.find({ key: 'group:major' })).toBeUndefined()

  const text = (await ui.find(item(`${fingerprint('src/a.ts', 'Crash')}#1`)))?.text

  expect(text).toContain('src/a.ts:12')
  expect(text).toContain('Crash')
  expect(text).toContain('The old value is returned')
  expect(text).toContain('Write first')
})

test('an unverified finding is labelled, and a refuted one sits behind a toggle with the verifier\'s reason', async ($, on) => {
  world(on, {
    'ab12cd34-r1.json': saved({
      findings: [],
      unverified: [finding({ claim: 'Maybe' })],
      refuted: [finding({ claim: 'Nope', why: 'it is freed on exit' })],
    }),
  })
  await start($)
  await run($, 'debate-board')

  const ui = await pane($)

  expect((await ui.find(item(`${fingerprint('src/a.ts', 'Maybe')}#1`)))?.text).toContain('(unverified)')
  expect(await ui.find({ key: 'refuted:0' })).toBeUndefined()
  await ui.press({ key: 'refuted-toggle' })
  expect((await ui.find({ key: 'refuted:0' }))?.text).toContain('it is freed on exit')
})

test('a report with no findings still opens, and says so', async ($, on) => {
  world(on, { 'ab12cd34-r1.json': saved({ findings: [] }) })
  await start($)

  expect((await run($, 'debate-board')).text).toContain('0 open of 0')
  expect(await (await pane($)).find({ key: 'empty' })).toBeDefined()
})

test('a report with an unreadable seat still shows the findings that were read', async ($, on) => {
  world(on, { 'ab12cd34-r1.json': saved({ seatState: { executor: 'reported', auditor: 'unreadable' } }) })
  await start($)

  expect((await run($, 'debate-board')).text).toContain('1 open of 1')
})

test('Mark done and Dismiss record a decision in the store; Reopen takes it back', async ($, on) => {
  const w = world(on, { 'ab12cd34-r1.json': saved() })
  await start($)
  await run($, 'debate-board')

  const ui = await pane($)

  await ui.press({ key: `done:${KEY}` })

  expect((await ui.find(item(KEY)))?.text).toContain('[done]')
  expect(w.store['board:ab12cd34']).toEqual({ [KEY]: 'done' })

  await ui.press({ key: `reopen:${KEY}` })

  expect((await ui.find(item(KEY)))?.text).not.toContain('[')
  expect(w.store['board:ab12cd34']).toBeUndefined()

  await ui.press({ key: `dismiss:${KEY}` })

  expect(w.store['board:ab12cd34']).toEqual({ [KEY]: 'dismissed' })
})

test('a dismissed finding stays dismissed in the next round even when its line moves, and a new finding starts open', async ($, on) => {
  const disk: Disk = { 'ab12cd34-r1.json': saved({}, 1000) }

  world(on, disk)
  await start($)
  await run($, 'debate-board')

  const ui = await pane($)

  await ui.press({ key: `dismiss:${KEY}` })

  disk['ab12cd34-r2.json'] = saved({ round: 2, findings: [finding({ line: 40 }), finding({ claim: 'Brand new', file: 'src/b.ts' })] }, 2000)
  await run($, 'debate-board')

  expect((await ui.find(item(KEY)))?.text).toContain('[dismissed]')
  expect((await ui.find(item(`${fingerprint('src/b.ts', 'Brand new')}#1`)))?.text).not.toContain('[')
})

test('decisions for a report that has been pruned are dropped when the board opens', async ($, on) => {
  const w = world(on, { 'ab12cd34-r1.json': saved() })
  await start($)
  await run($, 'debate-board')
  await (await pane($)).press({ key: `done:${KEY}` })
  w.store['board:deadbeef'] = { '0123456789abcdef#1': 'done' }
  await run($, 'debate-board')

  expect(w.store['board:deadbeef']).toBeUndefined()
  expect(w.store['board:ab12cd34']).toEqual({ [KEY]: 'done' })
})

test('a planted report is cleaned when drawn, and an oversized one is not even read', async ($, on) => {
  const w = world(on, {
    'ffffffff-r1.json': { text: '{}', mtimeMs: 3000, size: 3 * 1024 * 1024 },
    'eeeeeeee-r1.json': saved({ id: 'eeeeeeee', findings: [finding({ file: '../../.ssh/authorized_keys', claim: 'x‮y' })] }, 2000),
    'ab12cd34-r1.json': saved({}, 1000),
  })
  await start($)
  await run($, 'debate-board')

  const text = (await (await pane($)).find(item(`${fingerprint('(unsafe path)', 'xy')}#1`)))?.text

  expect(text).toContain('(unsafe path)')
  expect(text).toContain('xy')
  expect(text).not.toContain('‮')
  expect(w.reads).not.toContain(`${DIR}/ffffffff-r1.json`)
})

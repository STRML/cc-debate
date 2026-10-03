import { describe, expect, test } from 'claude-code/testing'

import { acpxSeats, findWorkDir, panelSeats, progress, seatsFrom } from '../../hooks/seats/lib'

describe('findWorkDir', () => {
  test('reads the work dir from an absolute file path', async () => {
    expect(findWorkDir({ file_path: '/Users/x/proj/.tmp/ai-review-ab12cd34/plan.md' }, '/Users/x/proj')).toBe(
      '/Users/x/proj/.tmp/ai-review-ab12cd34',
    )
  })

  test('resolves a relative mention against the session folder', async () => {
    expect(findWorkDir({ command: 'ls .tmp/ai-review-ab12cd34' }, '/Users/x/proj')).toBe('/Users/x/proj/.tmp/ai-review-ab12cd34')
  })

  test('finds it nested in a tool\'s arguments, as a Workflow call carries it', async () => {
    expect(findWorkDir({ name: 'review-panel', args: { workDir: '/Users/x/proj/.tmp/ai-review-ab12cd34' } }, '/Users/x/proj')).toBe(
      '/Users/x/proj/.tmp/ai-review-ab12cd34',
    )
  })

  test('answers null when the call names no review folder', async () => {
    expect(findWorkDir({ command: 'npm test', file_path: '/Users/x/proj/src/a.ts' }, '/Users/x/proj')).toBeNull()
  })

  test('accepts only a folder named like the ones debate-setup.sh makes: 8 lowercase hex characters', async () => {
    expect(findWorkDir({ command: 'ls .tmp/ai-review-ab12cd3' }, '/Users/x/proj')).toBeNull()
    expect(findWorkDir({ command: 'ls .tmp/ai-review-ab12cd34ef' }, '/Users/x/proj')).toBeNull()
    expect(findWorkDir({ command: 'ls .tmp/ai-review-AB12CD34' }, '/Users/x/proj')).toBeNull()
    expect(findWorkDir({ file_path: '/Users/x/proj/.tmp/ai-review-ab12cd34/plan.md' }, '/Users/x/proj')).toBe('/Users/x/proj/.tmp/ai-review-ab12cd34')
  })

  test('skips a path that climbs with .. and keeps looking', async () => {
    expect(findWorkDir({ command: 'cat ../../.tmp/ai-review-ab12cd34/x' }, '/Users/x/proj')).toBeNull()
    expect(findWorkDir({ a: '../.tmp/ai-review-ab12cd34', b: '/Users/x/proj/.tmp/ai-review-cd34ef56' }, '/Users/x/proj')).toBe(
      '/Users/x/proj/.tmp/ai-review-cd34ef56',
    )
  })
})

describe('panelSeats', () => {
  const panel = JSON.stringify({
    distinct_labs: 2,
    seats: {
      executor: { harness: 'acpx', model_id: 'm1' },
      antigravity: { harness: 'acpx', model_id: 'm2' },
      deepseek: { harness: 'subagent', model_id: 'm3' },
    },
  })

  test('the acpx seats are the ones the selector assigned to the acpx harness', async () => {
    expect(panelSeats(panel)).toEqual(['executor', 'antigravity'])
  })

  test('a manifest that cannot be read names no seats', async () => {
    expect(panelSeats('nope')).toEqual([])
    expect(panelSeats('{"seats":[]}')).toEqual([])
    expect(panelSeats('{}')).toEqual([])
  })
})

describe('acpxSeats', () => {
  const file = (name: string, size = 100) => ({ name, size })

  test('the manifest names the seats; a seat the runner left an invoke log for joins them', async () => {
    expect(acpxSeats(['executor'], [file('executor-invoke.log'), file('kimi-invoke.log'), file('plan.md', 0)])).toEqual([
      'executor',
      'kimi',
    ])
  })

  test('with no manifest, the invoke logs are all there is to go on', async () => {
    expect(acpxSeats([], [file('codex-invoke.log'), file('codex-stderr.log')])).toEqual(['codex'])
  })
})

describe('seatsFrom', () => {
  const file = (name: string, size = 100) => ({ name, size })

  // An acpx seat's files carry no round and no pattern beyond its own name: <seat>-exit.txt, <seat>-output.md.
  const files = [
    file('codex-exit.txt', 2),
    file('codex-output.md', 3000),
    file('gemini-exit.txt', 2),
    file('mute-exit.txt', 2),
    file('mute-output.md', 0),
  ]
  const exits = { codex: '0\n', gemini: '2\n', mute: '0\n' }
  // Agents are matched by what they were told to write into the panel's folder, so their names can be anything.
  const agents = [
    { name: 'Opus skeptic, round one', status: 'completed' },
    { name: 'grounder', status: 'running' },
    { name: 'opus-r2', status: 'killed' },
  ]

  const seats = seatsFrom(['codex', 'gemini', 'kimi', 'mute'], files, exits, agents)
  const by = (name: string) => seats.find(seat => seat.name === name)

  test('an acpx seat is done on exit 0 with a review, failed on any other exit, running with no exit yet', async () => {
    expect(by('codex')).toMatchObject({ harness: 'acpx', state: 'done' })
    expect(by('gemini')).toMatchObject({ harness: 'acpx', state: 'failed', detail: 'exit 2' })
    expect(by('kimi')).toMatchObject({ harness: 'acpx', state: 'running' })
  })

  test('exit 0 with an empty or missing review is a mute seat, not a success', async () => {
    expect(by('mute')).toMatchObject({ state: 'failed', detail: 'exit 0 but no review' })
    expect(seatsFrom(['quiet'], [file('quiet-exit.txt', 2)], { quiet: '0' }, [])[0]).toMatchObject({
      state: 'failed',
      detail: 'exit 0 but no review',
    })
  })

  test('an agent seat follows its agent\'s status, whatever it is called', async () => {
    expect(by('Opus skeptic, round one')).toMatchObject({ harness: 'subagent', state: 'done' })
    expect(by('grounder')).toMatchObject({ harness: 'subagent', state: 'running' })
    expect(by('opus-r2')).toMatchObject({ harness: 'subagent', state: 'failed', detail: 'killed' })
  })

  test('files nobody asked about are not seats', async () => {
    expect(seats.map(seat => seat.name)).not.toContain('plan')
    expect(seats).toHaveLength(7)
  })

  test('acpx seats list first, then agents, each by name', async () => {
    expect(seats.map(seat => seat.name)).toEqual(['codex', 'gemini', 'kimi', 'mute', 'Opus skeptic, round one', 'grounder', 'opus-r2'].sort((a, b) => {
      const acpx = ['codex', 'gemini', 'kimi', 'mute']

      return Number(!acpx.includes(a)) - Number(!acpx.includes(b)) || (a < b ? -1 : a > b ? 1 : 0)
    }))
  })
})

describe('progress', () => {
  test('counts what is done, running and failed', async () => {
    expect(
      progress([
        { name: 'a', harness: 'acpx', state: 'done' },
        { name: 'b', harness: 'acpx', state: 'running' },
        { name: 'c', harness: 'subagent', state: 'failed' },
      ]),
    ).toEqual({ total: 3, done: 1, running: 1, failed: 1 })
  })
})

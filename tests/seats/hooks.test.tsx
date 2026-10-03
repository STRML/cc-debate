import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { standIn } from './stand-in'

const BAND = { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 100 } as never
const PANE = { title: 'Debate seats', isFocused: true, bodyColumns: 100, placement: 'inline' } as never
const DIR = '/Users/x/proj/.tmp/ai-review-ab12cd34'

type Status = 'running' | 'completed'

/** A machine with a panel's folder, its seats' exit and output files, and two Agents (only one is the panel's). */
const world = (on: On) => {
  const clock = mock.clock(on, { now: new Date(2026, 9, 2, 15, 0, 0).getTime() })
  const toasts: string[] = []
  const state = {
    agent: 'running' as Status,
    gemini: false,
    // The manifest names the acpx seats; each leaves <seat>-exit.txt and <seat>-output.md when it ends.
    files: () => [
      ['plan.md', 0],
      ['panel.json', 300],
      ['codex-exit.txt', 2],
      ['codex-output.md', 4000],
      ...(state.gemini ? [['gemini-exit.txt', 2] as const, ['gemini-output.md', 3000] as const] : []),
    ] as readonly (readonly [string, number])[],
  }

  on('session.start', () => ({ cwd: '/Users/x/proj' }))
  on('session.cwd', () => ({ value: '/Users/x/proj' }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.close', () => ({ value: undefined }))
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)

    return { value: undefined }
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine band</Text>
  })
  on('tool.call', () => ({ result: {}, text: 'ok' }))
  on('fs.exists', (_$, e) => ({ value: e.path === DIR }))
  on('fs.list', (_$, e) => ({
    value: e.path === DIR ? state.files().map(([name, size]) => ({ name, kind: 'file', size, mtimeMs: 0, isLink: false })) : [],
  }))
  on('fs.read', (_$, e) => {
    if (e.path === `${DIR}/panel.json`) {
      return { value: JSON.stringify({ seats: { codex: { harness: 'acpx' }, gemini: { harness: 'acpx' }, deepseek: { harness: 'subagent' } } }) }
    }

    if (e.path === `${DIR}/codex-exit.txt`) return { value: '0\n' }
    if (e.path === `${DIR}/gemini-exit.txt`) return { value: '0\n' }

    return { deny: `ENOENT ${e.path}` }
  })
  // Two Agents exist; only the one whose prompt names the panel's folder is a seat.
  on('agent.spawn', (_$, e) => ({ model: 'opus', agentId: e.prompt.includes('stray') ? 'a2' : 'a1' }))
  on('agent.list', () => ({
    value: [
      { id: 'old', description: 'an earlier panel', type: 'general-purpose', status: 'completed', name: 'grounder-r1' },
      { id: 'a1', description: 'grounder reviewer', type: 'general-purpose', status: state.agent, name: 'Grounder (round 1)' },
      { id: 'a2', description: 'unrelated', type: 'general-purpose', status: 'running', name: 'stray' },
    ],
  }))

  return { clock, toasts, state }
}

/** Starts a session. */
const start = ($: any) => $.session.start({ cwd: '/Users/x/proj', surface: 'terminal', isInteractive: true })
/** Mounts the seat band above the prompt. */
const band = ($: any) => $.ui.mount({ plugin: 'debate', surface: 'terminal', component: 'AbovePrompt', props: BAND })
/** A tool call that names the panel's folder, as the orchestrator's first write does. */
const sawPlan = ($: any) => $.tool.call({ tool: 'Write', file_path: `${DIR}/plan.md`, content: 'plan' })

/** The panel's folder appears, then its teammate spawns (told to write into it) beside an unrelated Agent. */
const panelStarts = async ($: any, w: ReturnType<typeof world>) => {
  await sawPlan($)
  await $.agent.spawn({
    prompt: `Review the plan. Write your review to ${DIR}/grounder-output.md`,
    description: 'grounder reviewer',
    subagentType: 'general-purpose',
    name: 'Grounder (round 1)',
  })
  await $.agent.spawn({ prompt: 'an unrelated stray task', description: 'unrelated', subagentType: 'general-purpose', name: 'stray' })
  await w.clock.advance(5_000)
}
/** Runs /debate-seats as typed in the composer. */
const run = ($: any) =>
  $.command.run({ command: 'debate-seats', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 120 } })

test('the band stays quiet until a debate panel has been seen', async ($, on) => {
  world(on)
  await start($)

  const ui = await band($)

  expect(await ui.find({ key: 'band' })).toBeUndefined()
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
})

test('once a panel starts, the band counts seats done and running', async ($, on) => {
  const w = world(on)
  await start($)
  await panelStarts($, w)

  const text = (await (await band($)).find({ key: 'band' }))?.text

  expect(text).toContain('Debate')
  expect(text).toContain('1/3 seats done')
  expect(text).toContain('2 running')
})

test('the band clears and a toast says so when the last seat finishes', async ($, on) => {
  const w = world(on)
  const { clock, toasts, state } = w
  await start($)
  await panelStarts($, w)

  state.agent = 'completed'
  state.gemini = true
  await clock.advance(5_000)

  expect(await (await band($)).find({ key: 'band' })).toBeUndefined()
  expect(toasts.some(text => text.includes('3 seats'))).toBe(true)
})

test('/seats lists every seat with its state', async ($, on) => {
  const w = world(on)
  await start($)
  await panelStarts($, w)

  const reply = await run($)
  const ui = await $.ui.mount({ plugin: 'debate', surface: 'terminal', component: 'Pane', requestId: 'debate-seats', props: PANE })

  expect(reply.text).toContain('3 seats')
  expect((await ui.find({ key: 'seat:codex' }))?.text).toContain('done')
  expect((await ui.find({ key: 'seat:gemini' }))?.text).toContain('running')
  expect((await ui.find({ key: 'seat:Grounder (round 1)' }))?.text).toContain('running')
  expect(await ui.find({ key: 'seat:stray' })).toBeUndefined()
  expect(await ui.find({ key: 'seat:grounder-r1' })).toBeUndefined()
  expect(await ui.find({ key: 'seat:deepseek' })).toBeUndefined()
})

test('/seats says so when no panel has been seen', async ($, on) => {
  world(on)
  await start($)

  expect((await run($)).text).toContain('No debate panel')
})

for (const tier of ['append', 'prepend'] as const) {
  test(`the band shares the slot with another plugin's row, and keeps the engine's (${tier})`, { plugins: [standIn(tier)] }, async ($, on) => {
    const w = world(on)
    await start($)
    await panelStarts($, w)

    const ui = await band($)

    expect(await ui.find({ key: 'band' })).toBeDefined()
    expect(await ui.find({ text: 'stand-in row' })).toBeDefined()
    expect(await ui.find({ text: 'engine band' })).toBeDefined()
  })
}

test('a command that starts with an absolute path still finds the panel folder it names', async ($, on) => {
  world(on)
  await start($)
  await $.tool.call({ tool: 'Bash', command: `/usr/bin/env bash ${DIR}/run.sh` })

  expect((await run($)).text).not.toContain('No debate panel')
})

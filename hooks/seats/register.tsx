import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { acpxSeats, findWorkDir, panelSeats, progress, seatsFrom } from './lib'

const PANE = 'debate-seats'

const workDir = atom({ plugin: 'debate', key: 'seatsWorkDir' } as const, null)
const seats = atom({ plugin: 'debate', key: 'seatsRows' } as const, [])
const spawned = atom({ plugin: 'debate', key: 'seatsSpawned' } as const, [])
const isHidden = atom({ plugin: 'debate', key: 'seatsHidden' } as const, false)

let wasRunning = false

const readText = async ($: EngineInterface, path: string): Promise<string | null> => {
  try {
    const text = await $.fs.read(path)

    return typeof text === 'string' ? text : null
  } catch {
    return null
  }
}

const scan = async ($: EngineInterface) => {
  const [dir, mine, agents] = await Promise.all([read($, workDir), read($, spawned), $.agent.list()])

  if (dir === null) return []

  let files: { name: string; size: number }[] = []

  try {
    files = (await $.fs.list(dir)).map(entry => ({ name: entry.name, size: entry.size }))
  } catch {
    files = []
  }

  const names = acpxSeats(panelSeats((await readText($, `${dir}/panel.json`)) ?? ''), files)
  const exits: Record<string, string> = {}

  for (const name of names) {
    if (files.some(file => file.name === `${name}-exit.txt`)) {
      const text = await readText($, `${dir}/${name}-exit.txt`)

      if (text !== null) exits[name] = text
    }
  }

  // An Agent is a seat of this panel when its prompt named this panel's folder.
  const teammates = mine
    .filter(seat => seat.dir === dir)
    .flatMap(seat => {
      const agent = agents.find(one => one.id === seat.id)

      return agent === undefined ? [] : [{ name: seat.name, status: agent.status }]
    })

  return seatsFrom(names, files, exits, teammates)
}

const refresh = async ($: EngineInterface) => {
  const next = await scan($)
  const { total, done, running, failed } = progress(next)

  await update($, seats, () => next)

  if (wasRunning && running === 0 && total > 0) {
    $.ui.toast(`Debate panel finished: ${total} seats, ${done} done${failed > 0 ? `, ${failed} failed` : ''}.`)
  }

  wasRunning = running > 0
}

const open = ($: EngineInterface) => $.ui.open({ id: PANE, title: 'Debate seats', focus: true, closeOnEscape: true })

const COLOR = { running: 'yellow', done: 'green', failed: 'red' } as const
const MARK = { running: '●', done: '✓', failed: '✗' } as const

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'debate-seats', description: 'Which debate seats are running, done or failed' })
    await update($, workDir, () => null)
    await update($, spawned, () => [])
    wasRunning = false
    $.clock.every(5_000, () => refresh($))

    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const found = findWorkDir(e as unknown as Record<string, unknown>, await $.session.cwd())

    if (found !== null && found !== (await read($, workDir)) && (await $.fs.exists(found))) {
      wasRunning = false
      await update($, workDir, () => found)
      await update($, isHidden, () => false)
      await refresh($)
    }

    return next(e)
  })

  // The panel's Claude teammates and subagent-harness seats are told to write into the panel's folder, so
  // their prompt names it. That relationship, not their name, makes them seats.
  on('agent.spawn', async ($, e, next) => {
    const result = await next(e)
    const dir = await read($, workDir)

    if (dir !== null && result.deny === undefined && result.agentId !== undefined && e.prompt.includes(dir)) {
      const seat = { id: result.agentId, name: e.name ?? e.description, dir }

      await update($, spawned, list => [...list.filter(one => one.id !== seat.id), seat])
      await refresh($)
    }

    return result
  })

  on('command.run', { command: 'debate-seats' }, async $ => {
    if ((await read($, workDir)) === null) return { text: 'No debate panel seen in this session yet.' }

    await refresh($)
    await open($)

    const { total, done, running, failed } = progress(await read($, seats))

    return { text: `Debate panel: ${total} seats (${done} done, ${running} running, ${failed} failed).` }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const [dir, list] = await Promise.all([read($, workDir), read($, seats)])

    return (
      <Box flexDirection="column">
        <Text dimColor>{dir ?? 'No panel seen yet.'}</Text>
        {list.length === 0 && <Text dimColor>No seats yet.</Text>}
        {list.map(seat => (
          <Box key={`seat:${seat.name}`} gap={1}>
            <Text color={COLOR[seat.state]}>{`${MARK[seat.state]} ${seat.name}  ${seat.harness}  ${seat.state}${seat.detail === undefined ? '' : ` (${seat.detail})`}`}</Text>
          </Box>
        ))}
      </Box>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = await read($, seats)
    const { total, done, running, failed } = progress(list)

    if (e.props.hasSurvey || running === 0 || (await read($, isHidden))) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    // Other plugins and the engine draw in this slot too: stack under them rather than replace them.
    const beneath = await next(e)

    return (
      <Box flexDirection="column">
        {beneath}
        <Box key="band">
          <Text dimColor>{`⚖ Debate: ${done}/${total} seats done · ${running} running${failed > 0 ? ` · ${failed} failed` : ''} `}</Text>
          <Button key="seats" label="Seats" variant="primary" onPress={() => open($)} />
          <Button key="hide" label="Hide" dimColor onPress={() => update($, isHidden, () => true)} />
        </Box>
      </Box>
    )
  })
}

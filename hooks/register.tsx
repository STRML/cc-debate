// The `debate` mod. The host follows `$` only inside the file that receives it, and allows `session.start` to be registered
// once per module, so every hook lives here: the seat pane and progress band (watching a panel run) and the findings board.
// Pure code is in seats/lib.ts and report/lib.ts.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { BoardItem, BoardView, Status } from '../types'
import { ARCHIVE_NAME, MAX_ARCHIVE_BYTES, bandText, boardOf, openCounts, readArchive, readStatuses, statusOf } from './report/lib'
import { acpxSeats, findWorkDir, panelSeats, progress, seatsFrom } from './seats/lib'

// --- Watching a panel: the seat pane and progress band ---

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

// --- Working a panel's findings: the board ---

const BOARD = 'debate-board'
const SEVERITIES = ['critical', 'major', 'minor', 'nit'] as const
const SEVERITY_COLOR = { critical: 'red', major: 'yellow', minor: 'cyan', nit: 'gray' } as const

const rootDir = atom({ plugin: 'debate', key: 'reportRoot' } as const, null)
const boardView = atom({ plugin: 'debate', key: 'reportBoard' } as const, null)
const isRefutedOpen = atom({ plugin: 'debate', key: 'reportRefutedOpen' } as const, false)
const bandFor = atom({ plugin: 'debate', key: 'reportBand' } as const, null)
const isBandHidden = atom({ plugin: 'debate', key: 'reportHidden' } as const, false)

type Listed = { name: string; id: string; mtimeMs: number; size: number }
type Loaded = { top: string | null; view: BoardView | null; unreadable: number; ids: ReadonlySet<string> | null }

/** The folder `seat-report.sh --archive` saves into. `$.fs` does not expand `~`, so it is built from HOME. */
const reportsDir = async ($: EngineInterface): Promise<string | null> => {
  const home = await $.env.get('HOME')

  return home === undefined || home === '' ? null : `${home}/.acpx/debate-reports`
}

/** The repo root the way the writer finds it: `git rev-parse --show-toplevel` from the session folder. */
const toplevel = async ($: EngineInterface): Promise<string | null> => {
  try {
    const { exitCode, stdout } = await $.process.run(['git', 'rev-parse', '--show-toplevel'], { cwd: await $.session.cwd() })
    const top = stdout.trim()

    return exitCode === 0 && top !== '' ? top : null
  } catch {
    return null
  }
}

/** The archive files in the folder, newest first, or null when it cannot be listed. A symlink is not an archive. */
const listed = async ($: EngineInterface, dir: string): Promise<Listed[] | null> => {
  try {
    return (await $.fs.list(dir))
      .flatMap(entry => {
        const hit = entry.kind === 'file' && !entry.isLink ? ARCHIVE_NAME.exec(entry.name) : null

        return hit === null ? [] : [{ name: entry.name, id: hit[1] ?? '', mtimeMs: entry.mtimeMs, size: entry.size }]
      })
      .sort((a, b) => b.mtimeMs - a.mtimeMs)
  } catch {
    return null
  }
}

/** The newest saved report for `top`, with the decisions saved for its panel. A file that cannot be read is counted and skipped. */
const loadBoard = async ($: EngineInterface, top: string): Promise<Omit<Loaded, 'top'>> => {
  const dir = await reportsDir($)
  const files = dir === null ? null : await listed($, dir)

  if (dir === null || files === null) return { view: null, unreadable: 0, ids: null }

  const ids = new Set(files.map(file => file.id))
  let unreadable = 0

  for (const file of files) {
    const text = file.size > MAX_ARCHIVE_BYTES ? null : await readText($, `${dir}/${file.name}`)
    const archive = text === null ? null : readArchive(text)

    if (archive === null) {
      unreadable += 1
    } else if (archive.root === top) {
      return { view: boardOf(archive, readStatuses(await $.store.get(`board:${archive.id}`))), unreadable, ids }
    }
  }

  return { view: null, unreadable, ids }
}

/** Resolves the root and loads its board into the atoms. Never throws: a hook must not break the session. */
const refreshBoard = async ($: EngineInterface): Promise<Loaded> => {
  try {
    const top = await toplevel($)
    const loaded = top === null ? { view: null, unreadable: 0, ids: null } : await loadBoard($, top)

    await update($, rootDir, () => top)
    await update($, boardView, () => loaded.view)

    return { top, ...loaded }
  } catch {
    return { top: null, view: null, unreadable: 0, ids: null }
  }
}

/** Decisions kept for a panel whose report has been pruned are dropped; the ids come from the same listing the board read. */
const dropOrphans = async ($: EngineInterface, ids: ReadonlySet<string>) => {
  for (const key of await $.store.keys()) {
    if (key.startsWith('board:') && !ids.has(key.slice('board:'.length))) await $.store.delete(key)
  }
}

/** Records Sean's decision on a finding; `open` removes it, and a panel with no decisions leaves no key behind. */
const mark = async ($: EngineInterface, key: string, status: Status) => {
  const view = await read($, boardView)

  if (view === null) return

  const statuses = { ...view.statuses }

  if (status === 'open') delete statuses[key]
  else statuses[key] = status

  await update($, boardView, () => ({ ...view, statuses }))

  if (Object.keys(statuses).length === 0) await $.store.delete(`board:${view.id}`)
  else await $.store.set(`board:${view.id}`, statuses)
}

const openBoard = ($: EngineInterface) => $.ui.open({ id: BOARD, title: 'Findings board', focus: true, closeOnEscape: true })

/** The panel's own save: the orchestrator runs `seat-report.sh --archive` through Bash. */
const isArchiveRun = (input: { command?: unknown }) => typeof input.command === 'string' && input.command.includes('seat-report.sh --archive')

const where = (file: string, line: number) => `${file}${line > 0 ? `:${line}` : ''}`

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'debate-seats', description: 'Which debate seats are running, done or failed' })
    await $.command.register({ name: 'debate-board', description: 'Findings from the last debate panel for this repo: work through them, or dismiss them' })
    await update($, workDir, () => null)
    await update($, spawned, () => [])
    wasRunning = false
    $.clock.every(5_000, () => refresh($))
    await update($, bandFor, () => null)
    await update($, isBandHidden, () => false)
    await refreshBoard($)

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

  // The panel saved its report: load it and let the band show. Only a Bash call that ran `seat-report.sh --archive` and
  // succeeded counts, so a report from an earlier session never raises the band. The seats part registers `tool.call`
  // without a matcher; this one carries `{ tool: 'Bash' }`, which the host treats as a separate registration.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const result = await next(e)

    if (isArchiveRun(e as unknown as { command?: unknown }) && result.deny === undefined && result.isError !== true) {
      const { view } = await refreshBoard($)

      if (view !== null) {
        await update($, bandFor, () => ({ id: view.id, round: view.round }))
        await update($, isBandHidden, () => false)
      }
    }

    return result
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

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const [view, band, hidden] = await Promise.all([read($, boardView), read($, bandFor), read($, isBandHidden)])

    if (e.props.hasSurvey || hidden || view === null || band === null || band.id !== view.id || band.round !== view.round) return next(e)

    const counts = openCounts(view)

    if (counts.open === 0) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    // Other plugins and the engine draw in this slot too: stack under them rather than replace them.
    const beneath = await next(e)

    return (
      <Box flexDirection="column">
        {beneath}
        <Box key="findings-band">
          <Text dimColor>{`${bandText(counts)} `}</Text>
          <Button key="findings-board" label="Board" variant="primary" onPress={() => openBoard($)} />
          <Button key="findings-hide" label="Hide" dimColor onPress={() => update($, isBandHidden, () => true)} />
        </Box>
      </Box>
    )
  })

  on('command.run', { command: 'debate-board' }, async $ => {
    const { top, view, unreadable, ids } = await refreshBoard($)

    if (top === null) return { text: 'Not inside a git repository, so there is no findings board to show.' }

    if (view === null) {
      return { text: `No panel report for ${top}; changeset-mode panels save one.${unreadable > 0 ? ` ${unreadable} saved file(s) could not be read.` : ''}` }
    }

    if (ids !== null) await dropOrphans($, ids)

    await update($, isRefutedOpen, () => false)
    await openBoard($)

    return { text: `Findings board: ${openCounts(view).open} open of ${view.items.length} (panel ${view.id}, round ${view.round}).` }
  })

  on('ui.render', { component: 'Pane', requestId: BOARD }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const [view, refutedOpen] = await Promise.all([read($, boardView), read($, isRefutedOpen)])

    if (view === null) return <Text dimColor>No findings to show.</Text>

    const row = (one: BoardItem) => {
      const { finding, key } = one
      const status = statusOf(view, key)
      const tags = `${one.unverified ? ' (unverified)' : ''}${status === 'open' ? '' : ` [${status}]`}`

      return (
        <Box key={`finding:${key}`} flexDirection="column">
          <Text dimColor={status !== 'open'}>{`${where(finding.file, finding.line)}${tags}`}</Text>
          <Text dimColor={status !== 'open'}>{finding.claim}</Text>
          <Text dimColor>{`It fails: ${finding.failure}`}</Text>
          {finding.fix !== undefined && <Text dimColor>{`Fix: ${finding.fix}`}</Text>}
          <Box gap={1}>
            {status === 'open' && <Button key={`done:${key}`} label="Mark done" onPress={() => mark($, key, 'done')} />}
            {status === 'open' && <Button key={`dismiss:${key}`} label="Dismiss" dimColor onPress={() => mark($, key, 'dismissed')} />}
            {status !== 'open' && <Button key={`reopen:${key}`} label="Reopen" onPress={() => mark($, key, 'open')} />}
          </Box>
        </Box>
      )
    }

    return (
      <Box flexDirection="column">
        <Text dimColor>{`panel ${view.id}, round ${view.round}`}</Text>
        {view.items.length === 0 && (
          <Box key="empty">
            <Text dimColor>No findings in this report.</Text>
          </Box>
        )}
        {SEVERITIES.map(severity => {
          const items = view.items.filter(one => one.finding.severity === severity)

          return items.length === 0 ? null : (
            <Box key={`group:${severity}`} flexDirection="column">
              <Text color={SEVERITY_COLOR[severity]}>{`${severity} (${items.length})`}</Text>
              {items.map(row)}
            </Box>
          )
        })}
        {view.refuted.length > 0 && (
          <Box flexDirection="column">
            <Button
              key="refuted-toggle"
              label={`${refutedOpen ? 'Hide' : 'Show'} refuted (${view.refuted.length})`}
              dimColor
              onPress={() => update($, isRefutedOpen, shown => !shown)}
            />
            {refutedOpen &&
              view.refuted.map((finding, index) => (
                <Box key={`refuted:${index}`}>
                  <Text dimColor>{`✗ ${where(finding.file, finding.line)}  ${finding.claim}  (${finding.why ?? 'refuted'})`}</Text>
                </Box>
              ))}
          </Box>
        )}
      </Box>
    )
  })
}

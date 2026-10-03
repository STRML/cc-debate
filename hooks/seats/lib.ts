import type { Seat } from '../../types'

type FileLike = { name: string; size: number }

/** An agent the panel spawned: matched by what it was asked to do, not by what it is called. */
export type SeatAgent = { name: string; status: string }

// The panel's folder is `.tmp/ai-review-<id>`; debate-setup.sh makes the id 8 lowercase hex characters, and every script and
// prompt names the folder. The id must end there, so `ai-review-ab12cd34ef` and `ai-review-AB12CD34` are not panels.
const MENTION = /[^\s"'`=;|&()<>]*\.tmp\/ai-review-[0-9a-f]{8}(?![A-Za-z0-9_-])/g

const strings = (value: unknown, depth = 0): string[] => {
  if (typeof value === 'string') return [value]

  if (depth >= 4 || typeof value !== 'object' || value === null) return []

  return Object.values(value).flatMap(inner => strings(inner, depth + 1))
}

/** The panel's work folder, when a tool call names a `.tmp/ai-review-<id>` path (with no `..` in it) anywhere in its input. */
export const findWorkDir = (input: Record<string, unknown>, cwd: string): string | null => {
  for (const text of strings(input)) {
    for (const hit of text.matchAll(MENTION)) {
      const path = hit[0]

      if (!path.split('/').includes('..')) return path.startsWith('/') ? path : `${cwd}/${path.replace(/^\.\//, '')}`
    }
  }

  return null
}

/**
 * The acpx seats the selector assigned, read from the panel's own manifest (`panel.json`): the one place
 * the orchestrator writes down who is on the panel. Seats on the subagent harness are Agents; they are
 * seen through their spawn, not here.
 */
export const panelSeats = (panelJson: string): string[] => {
  try {
    const seats = (JSON.parse(panelJson) as { seats?: unknown }).seats

    if (typeof seats !== 'object' || seats === null || Array.isArray(seats)) return []

    return Object.entries(seats as Record<string, { harness?: unknown }>)
      .filter(([, seat]) => seat?.harness === 'acpx')
      .map(([name]) => name)
  } catch {
    return []
  }
}

/** The manifest's seats, plus any seat the runner left an invoke log for (a panel that ran without a manifest). */
export const acpxSeats = (manifest: readonly string[], files: readonly FileLike[]): string[] => {
  const names = new Set(manifest)

  for (const { name } of files) {
    const seat = /^(.+)-invoke\.log$/.exec(name)?.[1]

    if (seat !== undefined) names.add(seat)
  }

  return [...names]
}

const byName = (a: Seat, b: Seat) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)

/**
 * The panel's seats. An acpx seat is running until its `<seat>-exit.txt` appears; exit 0 is done only if
 * `<seat>-output.md` holds a review (a killed or mute seat can leave exit 0 behind with no output). An
 * agent seat is its agent's status.
 */
export const seatsFrom = (
  acpx: readonly string[],
  files: readonly FileLike[],
  exits: Readonly<Record<string, string>>,
  agents: readonly SeatAgent[],
): Seat[] => {
  const hasReview = (seat: string) => files.some(file => file.name === `${seat}-output.md` && file.size > 0)

  const processes = acpx.map((name): Seat => {
    const exit = exits[name]?.trim()

    if (exit === undefined) return { name, harness: 'acpx', state: 'running' }

    if (exit !== '0') return { name, harness: 'acpx', state: 'failed', detail: `exit ${exit}` }

    return hasReview(name)
      ? { name, harness: 'acpx', state: 'done' }
      : { name, harness: 'acpx', state: 'failed', detail: 'exit 0 but no review' }
  })

  const teammates = agents.map(
    ({ name, status }): Seat =>
      status === 'running'
        ? { name, harness: 'subagent', state: 'running' }
        : status === 'completed'
          ? { name, harness: 'subagent', state: 'done' }
          : { name, harness: 'subagent', state: 'failed', detail: status },
  )

  return [...processes.sort(byName), ...teammates.sort(byName)]
}

export const progress = (seats: readonly Seat[]) => ({
  total: seats.length,
  done: seats.filter(seat => seat.state === 'done').length,
  running: seats.filter(seat => seat.state === 'running').length,
  failed: seats.filter(seat => seat.state === 'failed').length,
})

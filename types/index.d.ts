/** One reviewer seat of a debate panel. */
export type Seat = {
  /** an acpx reviewer's name, or the name the panel gave its Agent teammate */
  name: string
  /** an Agent teammate, or an acpx process the panel script started */
  harness: 'subagent' | 'acpx'
  state: 'running' | 'done' | 'failed'
  /** why a seat failed, when known */
  detail?: string
}

/** An Agent the panel spawned: its prompt named the panel's work folder. */
export type SpawnedSeat = { id: string; name: string; dir: string }

export type Severity = 'critical' | 'major' | 'minor' | 'nit'

/** What Sean decided about a finding on the board; a finding with no entry is `open`. */
export type Status = 'open' | 'done' | 'dismissed'

/** How a seat fared in a saved report: it reported, failed, was never configured, or its review was never read. */
export type SeatState = 'reported' | 'failed' | 'not-configured' | 'unreadable'

/** A finding from a saved panel report, already cleaned for display. */
export type Finding = {
  file: string
  /** 0 when the reviewer gave no line */
  line: number
  severity: Severity
  claim: string
  failure: string
  fix?: string
  foundBy: string[]
  /** the verifier's reason, on a refuted finding */
  why?: string
}

export type BoardItem = {
  /** content key: stable across rounds of the same panel, so a dismissal survives a shifted line */
  key: string
  finding: Finding
  /** nobody ruled on it; shown as the reviewers filed it */
  unverified: boolean
}

/** The newest saved report for the repo being worked in, with Sean's decisions on its findings. */
export type BoardView = {
  id: string
  round: number
  root: string
  items: BoardItem[]
  refuted: Finding[]
  statuses: Record<string, Status>
}

/** One seat's round-1 record across saved reports. */
export type ScoreRow = {
  seat: string
  runs: number
  sole: number
  corroborated: number
  refuted: number
  /** runs whose estimated cost is known */
  costRuns: number
  costTotal: number
  model: string | null
}

declare module 'claude-code' {
  interface PluginState {
    debate: {
      /** the .tmp/ai-review-<id> folder of the panel being watched, once one has been seen */
      seatsWorkDir: string | null
      seatsRows: Seat[]
      /** Agents spawned for the panel in `seatsWorkDir`, by id */
      seatsSpawned: SpawnedSeat[]
      seatsHidden: boolean
      /** `git rev-parse --show-toplevel` from the session folder, the root a saved report is matched against */
      reportRoot: string | null
      reportBoard: BoardView | null
      /** the saved report a panel finished writing in this session; the band shows only for this one */
      reportBand: { id: string; round: number } | null
      reportHidden: boolean
      reportRefutedOpen: boolean
      reportScores: ScoreRow[] | null
    }
  }
}

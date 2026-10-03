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

declare module 'claude-code' {
  interface PluginState {
    debate: {
      /** the .tmp/ai-review-<id> folder of the panel being watched, once one has been seen */
      seatsWorkDir: string | null
      seatsRows: Seat[]
      /** Agents spawned for the panel in `seatsWorkDir`, by id */
      seatsSpawned: SpawnedSeat[]
      seatsHidden: boolean
    }
  }
}

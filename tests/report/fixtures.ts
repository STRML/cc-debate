export const ROOT = '/Users/x/proj'

/** A finding as the writer saves it; `over` replaces fields. */
export const finding = (over: Record<string, unknown> = {}) => ({
  file: 'src/a.ts',
  line: 12,
  severity: 'major',
  claim: 'Reads before it writes',
  failure: 'The old value is returned',
  fix: 'Write first',
  foundBy: ['executor'],
  ...over,
})

type Options = {
  id?: string
  round?: number
  root?: string
  ts?: string
  findings?: unknown[]
  refuted?: unknown[]
  unverified?: unknown[]
  seatState?: Record<string, string>
  seatMeta?: Record<string, unknown>
}

/** What `seat-report.sh --archive` saves, as text. */
export const archive = (options: Options = {}): string => {
  const findings = options.findings ?? [finding()]
  const refuted = options.refuted ?? []
  const unverified = options.unverified ?? []

  return JSON.stringify({
    v: 1,
    meta: { id: options.id ?? 'ab12cd34', round: options.round ?? 1, ts: options.ts ?? '2026-10-02T15:00:00Z', root: options.root ?? ROOT },
    seatState: options.seatState ?? { executor: 'reported', auditor: 'reported' },
    seatMeta: options.seatMeta ?? {
      executor: { model: 'gpt-6-luna', effort: 'medium', est_cost: 0.0135 },
      auditor: { model: 'gpt-6-sol', effort: 'high', est_cost: 0.415 },
    },
    report: {
      diff: null,
      seatsRun: ['executor', 'auditor'],
      seatsFailed: [],
      seatsNotConfigured: [],
      seatsNotTranscribed: [],
      seatsSkipped: [],
      counts: { raw: 0, locations: 0, distinct: 0, survived: findings.length, refuted: refuted.length, unverified: unverified.length },
      findings,
      refuted,
      unverified,
    },
  })
}

export const meta = {
  name: 'review-panel',
  description: 'Pick reviewer lenses from the diff, run them, dedupe the findings, verify what survives',
  whenToUse:
    'A code review where the panel size should follow the change rather than a fixed list. ' +
    'Needs a work dir already prepared by debate-setup.sh and a changeset.diff already written.',
  phases: [
    { title: 'Classify', detail: 'read the diff, measure it' },
    { title: 'Review', detail: 'run the selected seats through the existing runner' },
    { title: 'Extract', detail: 'turn each seat markdown into structured findings' },
    { title: 'Verify', detail: 'try to refute each surviving finding' },
    { title: 'Rank', detail: 'one ordered document' },
  ],
}

// The panel exists because its reviewers are NOT Claude. agent() here spawns Claude
// subagents, so none of them is a seat: they read the diff, they shell out to the
// runner that owns the real seats, they turn markdown into JSON, and they argue with
// findings. Every actual review still comes from acpx or codex-exec via
// invoke-acpx.sh. Ten agent() calls would be ten correlated reviewers, which is the
// failure debate-acpx.sample.json warns about in as many words.

const A = args || {}
const WORK_DIR = A.workDir
const CONFIG = A.configPath || '~/.claude/debate-acpx.json'
const REVIEW_ID = A.reviewId
const SCRIPTS = A.scriptDir || '~/.claude/debate-scripts'
const REPO = A.repoRoot || '.'

if (!WORK_DIR || !REVIEW_ID) {
  throw new Error('review-panel needs args {workDir, reviewId}; run debate-setup.sh first')
}

// --- lenses -----------------------------------------------------------------
//
// A lens is a seat plus the condition that earns it. Order matters only for
// reporting. `always` seats are the floor; the rest are bought by the diff.
//
// Measured on #22: twelve seats produced six distinct findings and five of them
// rediscovered the same one. The marginal seat pays when it brings a different
// question, not a different sample, so each entry here is a different question.

const LENSES = [
  { seat: 'executor', why: 'control flow', when: () => true },
  { seat: 'auditor', why: 'grounding, non-luna model', when: () => true },
  { seat: 'executor-b', why: 'state and lifecycle', when: (d) => d.filesChanged >= 3 || d.touchesFilesystem },
  { seat: 'cartographer', why: 'blast radius and doc drift', when: (d) => d.filesChanged >= 5 },
  { seat: 'pentester', why: 'attacker', when: (d) => d.securitySensitive },
  { seat: 'simplifier', why: 'argues for less code', when: (d) => d.linesAdded >= 150 || d.addsAbstraction },
  { seat: 'antigravity', why: 'the only non-OpenAI seat', when: (d) => !d.docsOnly },
]

// A docs-only change earns nothing but the floor, and the floor is one seat.
function pickSeats(d) {
  if (d.docsOnly) return ['auditor']
  const picked = LENSES.filter((l) => l.when(d)).map((l) => l.seat)
  return picked.length ? picked : ['executor', 'auditor']
}

const DIFF_SHAPE = {
  type: 'object',
  required: [
    'filesChanged', 'linesAdded', 'linesRemoved', 'docsOnly',
    'securitySensitive', 'touchesFilesystem', 'addsAbstraction', 'summary',
  ],
  properties: {
    filesChanged: { type: 'integer' },
    linesAdded: { type: 'integer' },
    linesRemoved: { type: 'integer' },
    docsOnly: { type: 'boolean', description: 'only markdown, comments or docs; no executable change' },
    securitySensitive: {
      type: 'boolean',
      description:
        'touches auth, credentials, secrets, crypto, permission checks, untrusted input, ' +
        'shelling out, or network endpoints',
    },
    touchesFilesystem: {
      type: 'boolean',
      description: 'reads or writes files or paths, or depends on a path existing',
    },
    addsAbstraction: {
      type: 'boolean',
      description: 'adds a layer, wrapper, indirection or new module',
    },
    summary: { type: 'string', description: 'one sentence, what the diff does' },
  },
}

const FINDINGS = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['file', 'line', 'severity', 'claim', 'failure'],
        properties: {
          file: { type: 'string', description: 'repo-relative path' },
          line: { type: 'integer', description: '0 if the finding is not line-anchored' },
          severity: { type: 'string', enum: ['critical', 'major', 'minor', 'nit'] },
          claim: { type: 'string', description: 'one sentence, the defect itself' },
          failure: { type: 'string', description: 'concrete inputs or state producing a concrete wrong result' },
          fix: { type: 'string' },
        },
      },
    },
  },
}

// Lower sorts first, and lower wins when two seats disagree about the same finding.
const RANK = { critical: 0, major: 1, minor: 2, nit: 3 }

const VERDICT = {
  type: 'object',
  required: ['refuted', 'reason'],
  properties: {
    refuted: { type: 'boolean', description: 'true if the finding does not hold' },
    reason: { type: 'string' },
    severityAfter: { type: 'string', enum: ['critical', 'major', 'minor', 'nit'] },
  },
}

// --- 1. classify -------------------------------------------------------------

phase('Classify')

const shape = await agent(
  `Read ${WORK_DIR}/changeset.diff and measure it. Do not review it and do not judge it.
Report only what is observably true of the diff.

If the file is missing or empty, say so by reporting every count as 0 and docsOnly true.

Repo root is ${REPO}. Read with absolute paths.`,
  { label: 'classify-diff', phase: 'Classify', schema: DIFF_SHAPE, effort: 'low' },
)

if (!shape) throw new Error('could not classify the diff; nothing downstream is safe')

const seats = pickSeats(shape)
log(`${shape.filesChanged} files, +${shape.linesAdded}/-${shape.linesRemoved}: ${shape.summary}`)
log(`seats: ${seats.join(', ')}`)
for (const l of LENSES) {
  if (!seats.includes(l.seat)) log(`  skipped ${l.seat} (${l.why}) — not earned by this diff`)
}

// --- 2. review ---------------------------------------------------------------
//
// One agent, not one per seat. run-parallel-acpx.sh already fans out, already owns
// the per-seat timeouts and the blank-turn retries, and already writes the exit
// files. Wrapping each seat in its own agent would duplicate that and buy nothing.

phase('Review')

await agent(
  `Run the review panel and report nothing else.

  cd ${REPO} && bash "${SCRIPTS}/run-parallel-acpx.sh" "${CONFIG}" "${REVIEW_ID}" "${seats.join(',')}"

It blocks until every seat finishes or its budget runs out, and it can take fifteen
minutes. Let it run. Do not kill it, do not poll it, do not summarise the reviews.

When it returns, reply with one line per seat: the seat name, the contents of
${WORK_DIR}/<seat>-exit.txt, and the byte size of ${WORK_DIR}/<seat>-output.md.`,
  { label: 'run-panel', phase: 'Review' },
)

// --- 3. extract --------------------------------------------------------------
//
// The step that makes the rest possible. Reviews arrive as markdown, and merging
// twelve markdown files by eye is the thing that scales worst about the current
// panel. Structured findings make the merge three lines of JS.

phase('Extract')

const perSeat = await pipeline(
  seats,
  (seat) =>
    agent(
      `Read ${WORK_DIR}/${seat}-output.md and transcribe its findings into the schema.

You are a transcriber. Do not review the code, do not add findings, do not upgrade or
downgrade a severity the reviewer chose, and do not drop a finding because you disagree
with it. If the file is missing, empty, or contains only an error message, return an
empty findings array.

Map the reviewer's own words: its P1/CRITICAL/blocker becomes critical, P2/MAJOR becomes
major, and so on. If a finding has no file or line, use the file it discusses and line 0.`,
      { label: `extract:${seat}`, phase: 'Extract', schema: FINDINGS, effort: 'low' },
    ).then((r) => ({ seat, findings: (r && r.findings) || [] })),
)

const bySeat = perSeat.filter(Boolean)
for (const s of bySeat) log(`${s.seat}: ${s.findings.length} finding(s)`)

// --- 4. dedupe ---------------------------------------------------------------
//
// Plain code, deliberately. On #22 five seats independently found one README drift,
// and the orchestrator deduped by reading twelve files. Same key, same finding.

function key(f) {
  return `${(f.file || '').trim().toLowerCase()}:${f.line || 0}`
}

const merged = new Map()
for (const { seat, findings } of bySeat) {
  for (const f of findings) {
    const k = key(f)
    const prev = merged.get(k)
    if (prev) {
      prev.seats.push(seat)
      // Keep the harshest severity anyone assigned; a seat that saw it as critical
      // saw something the others did not.
      if (RANK[f.severity] < RANK[prev.severity]) {
        prev.severity = f.severity
        prev.claim = f.claim
        prev.failure = f.failure
      }
    } else {
      merged.set(k, { ...f, seats: [seat] })
    }
  }
}

const unique = [...merged.values()]
const dupes = bySeat.reduce((n, s) => n + s.findings.length, 0) - unique.length
log(`${unique.length} distinct finding(s), ${dupes} duplicate(s) collapsed`)

// --- 5. verify ---------------------------------------------------------------
//
// Of twelve seats on #22, two produced findings that were wrong and cost a read each
// to disprove. False positives scale with headcount, so they get filtered before a
// human sees them, not after. Prompted to refute: the default answer is "it holds",
// and it takes an argument to move.

phase('Verify')

const judged = await parallel(
  unique.map((f) => () =>
    agent(
      `A reviewer claims:

  ${f.file}:${f.line} [${f.severity}] ${f.claim}
  It fails like this: ${f.failure}

Try to refute it. Open the file at ${REPO} and read the actual code, plus whatever
callers or tests bear on it. Refute it if the code does not say what the claim says,
if the failure cannot happen for a reason the reviewer missed, if it is already handled
elsewhere, or if it describes intended behaviour.

Do not refute it merely because it is small, or stylistic, or you would not have raised
it. Severity is not your call; truth is. If it holds, say so and leave the severity
alone unless the code shows the reviewer misjudged the impact.`,
      { label: `verify:${f.file}:${f.line}`, phase: 'Verify', schema: VERDICT },
    ).then((v) => ({ ...f, verdict: v })),
  ),
)

const checked = judged.filter(Boolean)
const survived = checked.filter((f) => f.verdict && !f.verdict.refuted)
const killed = checked.filter((f) => f.verdict && f.verdict.refuted)
log(`${survived.length} finding(s) survived, ${killed.length} refuted`)

// --- 6. rank -----------------------------------------------------------------

phase('Rank')

for (const f of survived) {
  if (f.verdict.severityAfter) f.severity = f.verdict.severityAfter
}

survived.sort((a, b) => {
  const s = RANK[a.severity] - RANK[b.severity]
  // A finding two seats reached independently outranks one that a single seat did,
  // at the same severity. Agreement is weak evidence, but it is evidence.
  return s !== 0 ? s : b.seats.length - a.seats.length
})

return {
  diff: shape,
  seatsRun: seats,
  seatsSkipped: LENSES.filter((l) => !seats.includes(l.seat)).map((l) => l.seat),
  counts: {
    raw: bySeat.reduce((n, s) => n + s.findings.length, 0),
    distinct: unique.length,
    survived: survived.length,
    refuted: killed.length,
  },
  findings: survived.map((f) => ({
    file: f.file,
    line: f.line,
    severity: f.severity,
    claim: f.claim,
    failure: f.failure,
    fix: f.fix,
    foundBy: f.seats,
  })),
  refuted: killed.map((f) => ({
    file: f.file,
    line: f.line,
    claim: f.claim,
    why: f.verdict.reason,
    foundBy: f.seats,
  })),
}

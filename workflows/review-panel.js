export const meta = {
  name: 'review-panel',
  description: 'Pick reviewer lenses from the diff, run them, dedupe the findings, verify what survives',
  // One string literal, not two joined by +. The loader parses meta as a pure literal
  // and rejects a BinaryExpression, so a concatenation here fails the whole workflow
  // before the first phase runs.
  whenToUse: 'A code review where the panel size should follow the change rather than a fixed list. Needs a work dir already prepared by debate-setup.sh and a changeset.diff already written.',
  phases: [
    { title: 'Classify', detail: 'read the diff, measure it' },
    { title: 'Extract', detail: 'turn each seat markdown into structured findings' },
    { title: 'Verify', detail: 'try to refute each surviving finding' },
    { title: 'Rank', detail: 'one ordered document' },
  ],
}

// The panel exists because its reviewers are NOT Claude. agent() here spawns Claude
// subagents, so none of them is a seat: they measure the diff, they turn markdown into
// JSON, and they argue with findings. Every actual review comes from an acpx or
// codex-exec seat that `/debate:panel` runs between this workflow's two stages. Ten
// agent() calls would be ten correlated reviewers, which is the failure
// debate-acpx.sample.json warns about in as many words.
//
// Two stages, and the split is forced rather than chosen. run-parallel-acpx.sh blocks
// for as long as its slowest seat is allowed to take, which is half an hour, and there
// is no way for a workflow agent() to wait that long: a foreground Bash call is capped
// at ten minutes, a foreground sleep is refused, and Monitor schedules a callback into
// a turn that has already ended. The subagent returns, the harness reaps the runner it
// backgrounded, and every seat dies mid-review. Only the main loop can wait on a long
// command, so the runner belongs to the command and this script runs either side of it.
//
//   stage: 'classify' -> measure the diff, pick the seats, return them
//   ...the command runs the seats and works out which ones reported...
//   stage: 'report'   -> extract, dedupe, verify and rank what they wrote

// args arrives verbatim from the caller. A caller that JSON-encodes it — easy to do,
// and the failure reads as "needs args {workDir}" while the args are sitting right
// there in the invocation — would otherwise land here as a string, where every
// property lookup is undefined.
const A = (typeof args === 'string' ? JSON.parse(args) : args) || {}
const WORK_DIR = A.workDir
const REPO = A.repoRoot || '.'
const STAGE = A.stage || 'classify'

if (!WORK_DIR) {
  throw new Error('review-panel needs args {workDir}; run debate-setup.sh first')
}
if (STAGE !== 'classify' && STAGE !== 'report') {
  throw new Error(`review-panel: unknown stage '${STAGE}'; expected 'classify' or 'report'`)
}

// Every path this script puts in a command goes through here. Two problems at once:
// a workflow has no filesystem access, so it cannot resolve `~` itself, and a repo
// path can contain spaces or quotes, which split a command into the wrong arguments.
// Single quotes solve the second and defeat the first, so a leading `~` is emitted as
// a separate "$HOME" token and the remainder is single-quoted:
//   ~/a/b       -> "$HOME"'/a/b'
//   /My Repo    -> '/My Repo'
//   /it's/here  -> '/it'\''s/here'
function shellArg(p) {
  const s = String(p)
  const tilde = /^~(?=\/|$)/.test(s)
  const rest = tilde ? s.slice(1) : s
  const quoted = `'${rest.replace(/'/g, `'\\''`)}'`
  return tilde ? `"$HOME"${quoted}` : quoted
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
  // The one seat that gets a floor under it. Every other lens can be talked out of by
  // the classifier, and the cost is a smaller panel. Here the cost is no attacker on
  // the exact diff that needed one, so a grep hit earns the seat whatever the model
  // concluded from reading.
  { seat: 'pentester', why: 'attacker', when: (d) => d.securitySensitive || d.securityGrep },
  { seat: 'simplifier', why: 'argues for less code', when: (d) => d.linesAdded >= 150 || d.addsAbstraction },
  { seat: 'antigravity', why: 'the only non-OpenAI seat', when: (d) => !d.docsOnly },
]

// A docs-only change earns nothing but the floor, and the floor is one seat — unless
// something in it tripped a security signal. The shortcut used to run first and return
// unconditionally, which quietly outranked the pentester's floor: a README whose install
// step had been edited to pipe a payload into a shell is docs-only, sets securityGrep,
// and got exactly one auditor. Docs are executable often enough to matter.
function pickSeats(d) {
  if (d.docsOnly && !d.securitySensitive && !d.securityGrep) return ['auditor']
  const picked = LENSES.filter((l) => l.when(d)).map((l) => l.seat)
  return picked.length ? picked : ['executor', 'auditor']
}

const DIFF_SHAPE = {
  type: 'object',
  required: [
    'filesChanged', 'linesAdded', 'linesRemoved', 'docsOnly',
    'securitySensitive', 'securityGrep', 'touchesFilesystem', 'addsAbstraction', 'summary',
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
    securityGrep: {
      type: 'boolean',
      description: 'whether the security grep printed HIT; report what it printed, do not judge it',
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

if (STAGE === 'classify') {

phase('Classify')

const shape = await agent(
  `Report the shape of the changeset at ${WORK_DIR}/changeset.diff. Do not review it and
do not judge it. Report only what is observably true of the diff.

Get the three counts by running exactly this and reporting what it prints:

  awk '/^diff --git /{f++; h=0; next} /^@@/{h=1; next} !h{next} /^\\+/{a++} /^-/{r++} END{printf "%d %d %d\\n", f+0, a+0, r+0}' ${shellArg(`${WORK_DIR}/changeset.diff`)}

It prints filesChanged, linesAdded and linesRemoved in that order. It counts only lines
inside a hunk, so a added line whose own text starts with +++ is not mistaken for a file
header. Do not count by reading. pickSeats branches on these numbers at fixed
thresholds, and a long diff is truncated before you reach the end of it, so a read count
is a guess that silently resizes the panel.

Then run this, and set securityGrep true for HIT, false for MISS:

  grep -qiE '(auth|credential|password|passwd|secret|token|api[_-]?key|crypt|hmac|signature|permission|sudo|chmod|eval|exec\\(|subprocess|shell=True|sanitiz|escape|injection)' ${shellArg(`${WORK_DIR}/changeset.diff`)}; case $? in 0) echo HIT;; 1) echo MISS;; *) echo ERROR;; esac

Report what it printed. Do not second-guess it: a HIT on a diff you judged harmless is
the case it exists for, and it only ever adds the attacker seat. If it prints ERROR then
grep itself failed and the answer is unknown — say so in the summary and report
securityGrep true, because an unknown must not read as an all-clear.

If the file is missing, report every count as 0 and docsOnly true.

Judge docsOnly, the three booleans and the summary by reading the diff — those are the
part that needs a reader. Repo root is ${REPO}. Read with absolute paths.`,
  { label: 'classify-diff', phase: 'Classify', schema: DIFF_SHAPE, effort: 'low' },
)

if (!shape) throw new Error('could not classify the diff; nothing downstream is safe')

// An empty diff classifies as zero-everything, which pickSeats reads as docsOnly and
// buys one seat for. But run-parallel-acpx.sh regenerates the changeset itself when no
// plan is staged, so the seats would go on to review a real change that was sized as a
// docs edit. Refuse rather than review one diff having measured another.
if (!shape.filesChanged && !shape.linesAdded && !shape.linesRemoved) {
  throw new Error(
    `${WORK_DIR}/changeset.diff is empty — write it with changeset-diff.sh before running the panel`,
  )
}

const seats = pickSeats(shape)
log(`${shape.filesChanged} files, +${shape.linesAdded}/-${shape.linesRemoved}: ${shape.summary}`)
log(`seats: ${seats.join(', ')}`)
for (const l of LENSES) {
  if (!seats.includes(l.seat)) log(`  skipped ${l.seat} (${l.why}) — not earned by this diff`)
}

// Stage one ends here. The command runs these seats and comes back with the ones that
// actually reported.
return {
  stage: 'classify',
  diff: shape,
  seats,
  seatsSkipped: LENSES.filter((l) => !seats.includes(l.seat)).map((l) => ({ seat: l.seat, why: l.why })),
}

} // end stage: 'classify'

// --- 2. report ---------------------------------------------------------------
//
// The seats have run by now. Which of them produced a review is a question about files
// on disk, so the command answers it — it has a filesystem and this does not — and
// passes the answer in. Guessing it here is what produced a clean report from a panel
// that never started.

const ran = A.seats || []
const failed = A.seatsFailed || []
const shape = A.diff || null
const seatsSkipped = A.seatsSkipped || []

for (const s of failed) log(`  ${s}: no review — not counted as run`)

if (!ran.length) {
  throw new Error(
    'review-panel stage report needs args {seats: [...]} naming the seats that produced a ' +
      'review. None were given, so there is nothing to extract.',
  )
}

// --- 3. extract --------------------------------------------------------------
//
// The step that makes the rest possible. Reviews arrive as markdown, and merging
// twelve markdown files by eye is the thing that scales worst about the current
// panel. Structured findings make the merge three lines of JS.

phase('Extract')

const perSeat = await pipeline(
  ran,
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
    ).then((r) => ({ seat, ok: !!r, findings: (r && r.findings) || [] })),
)

// A transcriber that died tells you nothing about what its seat found, and "nothing to
// report" is the one thing it must never be mistaken for. agent() returns null when the
// subagent hits a terminal error — a session limit, an API failure — and pipeline()
// yields null for an item whose stage threw. Both used to collapse into an empty
// findings array, which is indistinguishable from a reviewer who approved the diff.
// Observed for real: seven seats wrote 747-4989 bytes of review each, every extract
// agent hit a session limit, and the panel reported zero findings and looked clean.
// Results are positional, so a null maps back to the seat it belonged to.
const bySeat = ran.map((seat, i) => perSeat[i] || { seat, ok: false, findings: [] })
const extractFailed = bySeat.filter((s) => !s.ok).map((s) => s.seat)

for (const s of bySeat) {
  if (s.ok) log(`${s.seat}: ${s.findings.length} finding(s)`)
  else log(`${s.seat}: review could NOT be transcribed — its findings are missing here`)
}

if (extractFailed.length === ran.length) {
  throw new Error(
    `every seat reviewed but none could be transcribed (${extractFailed.join(', ')}). ` +
      `The reviews are on disk in ${WORK_DIR}; this is not a clean review, it is no review.`,
  )
}

// --- 4. dedupe ---------------------------------------------------------------
//
// Plain code, deliberately. On #22 five seats independently found one README drift,
// and the orchestrator deduped by reading twelve files. Same key, same finding.

// The claim is part of the key, at every line number. An earlier version keyed on
// file:line alone and kept the alternates in a side list, promoting the harshest to the
// headline — and lost a finding in both arrival orders, because promotion overwrote the
// headline without preserving it and the cleanup pass then removed the promoted claim
// from the alternates. Six of seven seats found that independently. Verification is the
// other half of the argument: it only ever sees the headline, so an alternate riding
// along on a refuted headline dies unexamined, which is a place to hide a real defect
// behind an obvious decoy on the same line.
//
// So: one record per distinct claim, each verified on its own. Two seats that word a
// finding the same way still merge and stack up in foundBy. Two seats that word it
// differently now produce two records, which over-reports rather than deletes — the
// right direction to err, and the verify step reads both.
//
// The path keeps its case. Lowercasing it merged src/Foo.js with src/foo.js on any
// case-sensitive checkout, and the survivor kept the other one's path.
function claimId(f) {
  return (f.claim || '').trim().toLowerCase().replace(/\s+/g, ' ')
}

function key(f) {
  return `${(f.file || '').trim()}:${f.line || 0}:${claimId(f)}`
}

const merged = new Map()
for (const { seat, findings } of bySeat) {
  for (const f of findings) {
    const k = key(f)
    const prev = merged.get(k)
    if (prev) {
      prev.seats.push(seat)
      // Same claim, harsher severity: a seat that saw it as critical saw something the
      // others did not. Nothing is lost here — the claim text is identical by key.
      if (RANK[f.severity] < RANK[prev.severity]) {
        prev.severity = f.severity
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

// filter(Boolean) drops nothing here: the .then above wraps every finding in a fresh
// object, so a verifier that timed out or came back malformed yields {..., verdict:
// null} — truthy, but in neither survived nor killed. Left implicit, an unrefuted
// finding disappears from the report with nothing said. Nobody argued it away, so it
// is reported separately rather than dropped.
const checked = judged.filter(Boolean)
const unverified = checked.filter((f) => !f.verdict)
const survived = checked.filter((f) => f.verdict && !f.verdict.refuted)
const killed = checked.filter((f) => f.verdict && f.verdict.refuted)
log(`${survived.length} finding(s) survived, ${killed.length} refuted, ${unverified.length} unverified`)

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
  stage: 'report',
  diff: shape,
  // seatsRun is what reported, not what was asked for. Reporting the request would
  // credit a seat that never ran with having found nothing.
  seatsRun: ran,
  seatsFailed: failed,
  // Seats that reviewed but whose review could not be read back. Their findings are
  // absent from everything below, so the report is incomplete by exactly this much.
  seatsNotTranscribed: extractFailed,
  // The reason a seat was skipped is the interesting half — it is what you argue with
  // when a lens keeps missing a change you wanted it on. Carried through from stage one.
  seatsSkipped,
  counts: {
    raw: bySeat.reduce((n, s) => n + s.findings.length, 0),
    distinct: unique.length,
    survived: survived.length,
    refuted: killed.length,
    unverified: unverified.length,
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
  // Nobody refuted these; the verifier just never came back. They are the reviewers'
  // claims as filed, unfiltered, and they are reported as exactly that.
  unverified: unverified.map((f) => ({
    file: f.file,
    line: f.line,
    severity: f.severity,
    claim: f.claim,
    failure: f.failure,
    foundBy: f.seats,
  })),
}

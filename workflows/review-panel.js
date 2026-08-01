export const meta = {
  name: 'review-panel',
  description: 'Pick reviewer lenses from the diff, run them, dedupe the findings, verify what survives',
  // One string literal, not two joined by +. The loader parses meta as a pure literal
  // and rejects a BinaryExpression, so a concatenation here fails the whole workflow
  // before the first phase runs.
  whenToUse: 'A code review where the panel size should follow the change rather than a fixed list. Needs a work dir already prepared by debate-setup.sh and a changeset.diff already written.',
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

// args arrives verbatim from the caller. A caller that JSON-encodes it — easy to do,
// and the failure reads as "needs args {workDir, reviewId}" while the args are sitting
// right there in the invocation — would otherwise land here as a string, where every
// property lookup is undefined.
const A = (typeof args === 'string' ? JSON.parse(args) : args) || {}
const WORK_DIR = A.workDir
const CONFIG = A.configPath || '~/.claude/debate-acpx.json'
const REVIEW_ID = A.reviewId
const SCRIPTS = A.scriptDir || '~/.claude/debate-scripts'
const REPO = A.repoRoot || '.'

if (!WORK_DIR || !REVIEW_ID) {
  throw new Error('review-panel needs args {workDir, reviewId}; run debate-setup.sh first')
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

phase('Classify')

const shape = await agent(
  `Report the shape of the changeset at ${WORK_DIR}/changeset.diff. Do not review it and
do not judge it. Report only what is observably true of the diff.

Get the three counts by running exactly this and reporting what it prints:

  awk '/^diff --git /{f++} /^\\+\\+\\+ |^--- /{next} /^\\+/{a++} /^-/{r++} END{printf "%d %d %d\\n", f+0, a+0, r+0}' ${shellArg(`${WORK_DIR}/changeset.diff`)}

It prints filesChanged, linesAdded and linesRemoved in that order. Do not count by
reading. pickSeats branches on these numbers at fixed thresholds, and a long diff is
truncated before you reach the end of it, so a read count is a guess that silently
resizes the panel.

Then run this, and set securityGrep true if it prints HIT and false if it prints MISS:

  grep -qiE '(auth|credential|password|passwd|secret|token|api[_-]?key|crypt|hmac|signature|permission|sudo|chmod|eval|exec\\(|subprocess|shell=True|sanitiz|escape|injection)' ${shellArg(`${WORK_DIR}/changeset.diff`)} && echo HIT || echo MISS

Report what it printed. Do not second-guess it: a HIT on a diff you judged harmless is
the case it exists for, and it only ever adds the attacker seat.

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

// --- 2. review ---------------------------------------------------------------
//
// One agent, not one per seat. run-parallel-acpx.sh already fans out, already owns
// the per-seat timeouts and the blank-turn retries, and already writes the exit
// files. Wrapping each seat in its own agent would duplicate that and buy nothing.

phase('Review')

const RUN_STATUS = {
  type: 'object',
  required: ['seats'],
  properties: {
    seats: {
      type: 'array',
      items: {
        type: 'object',
        required: ['seat', 'exit', 'bytes'],
        properties: {
          seat: { type: 'string' },
          exit: { type: 'integer', description: '-1 if the seat never wrote an exit file' },
          bytes: { type: 'integer', description: 'size of <seat>-output.md, 0 if missing' },
        },
      },
    },
  },
}

const run = await agent(
  `Run the review panel and report what each seat did. Review nothing yourself.

  cd ${shellArg(REPO)} && bash ${shellArg(`${SCRIPTS}/run-parallel-acpx.sh`)} ${shellArg(CONFIG)} ${shellArg(REVIEW_ID)} ${shellArg(seats.join(','))}

Start that with run_in_background: true AND dangerouslyDisableSandbox: true. Both are
load-bearing:

- Background, because the runner budgets timeout x (retries + 1) + 60s for its slowest
  seat — up to 31 minutes for the 900s seats — and one Bash call is capped at 10. A
  foreground call is killed mid-panel, and every seat it was still waiting on then looks
  exactly like a seat that reviewed the diff and found nothing.
- Unsandboxed, because the seats need outbound network and the antigravity seat writes
  its project config under ~/.gemini before it can open a conversation. Sandboxed, that
  write is denied and the seat returns nothing. What keeps the seats read-only is not
  the sandbox but their own permission mode: acpx runs them with --approve-reads and
  --non-interactive-permissions deny, and antigravity gets a throwaway workspace plus
  --sandbox. Dropping the outer sandbox removes a second layer, not the only one — but
  it does mean a seat's read-only guarantee now rests entirely on that flag being right.

Then wait for every one of these to exist:

  ${seats.map((s) => `${WORK_DIR}/${s}-exit.txt`).join('\n  ')}

Wait with Monitor and an until-loop over those paths. A foreground sleep is blocked by
the harness, so if Monitor is unavailable, re-check with a fresh short Bash call each
time instead of sleeping between checks. Give up after 35 minutes. Do not kill the
runner, do not read the reviews, do not summarise them.

Report one entry per seat: its name, the integer in ${WORK_DIR}/<seat>-exit.txt (-1 if
that file never appeared), and the byte size of ${WORK_DIR}/<seat>-output.md (0 if it is
missing).`,
  { label: 'run-panel', phase: 'Review', schema: RUN_STATUS },
)

// What the runner did is the difference between "reviewed and found nothing" and "never
// ran". The extract stage maps a missing output file to an empty findings array, so
// without this check a runner that failed to start returns the cleanest report the panel
// can produce. A seat is only counted as run if it exited 0 and wrote something.
const reported = new Map(((run && run.seats) || []).map((s) => [s.seat, s]))
const ran = seats.filter((s) => {
  const st = reported.get(s)
  return st && st.exit === 0 && st.bytes > 0
})
const failed = seats.filter((s) => !ran.includes(s))

for (const s of failed) {
  const st = reported.get(s)
  // exit -1 also covers a lens the config has no entry for: run-parallel-acpx.sh skips
  // an unknown seat without failing, so the only trace is the exit file never appearing.
  log(`  ${s}: no review (exit ${st ? st.exit : 'unknown'}, ${st ? st.bytes : 0} bytes) — not counted as run`)
}

if (!ran.length) {
  throw new Error(
    `no seat produced a review (asked for: ${seats.join(', ')}). The runner did not start, ` +
      `was killed, or none of these seats exists in ${CONFIG}.`,
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
    ).then((r) => ({ seat, findings: (r && r.findings) || [] })),
)

const bySeat = perSeat.filter(Boolean)
for (const s of bySeat) log(`${s.seat}: ${s.findings.length} finding(s)`)

// --- 4. dedupe ---------------------------------------------------------------
//
// Plain code, deliberately. On #22 five seats independently found one README drift,
// and the orchestrator deduped by reading twelve files. Same key, same finding.

// file:line is the right key for a line-anchored finding — two seats pointing at one
// line found one thing. It is the wrong key at line 0, which the schema tells a seat to
// use whenever a finding is not line-anchored: every file-level finding in a file would
// collide on `readme.md:0` and all but the harshest would be dropped as a duplicate.
// There the claim is the only identity available, so use it.
function key(f) {
  const file = (f.file || '').trim().toLowerCase()
  const line = f.line || 0
  if (line > 0) return `${file}:${line}`
  return `${file}:0:${(f.claim || '').trim().toLowerCase().replace(/\s+/g, ' ')}`
}

// Two seats on one line usually found one defect, which is why the key stays
// file:line. Usually is not always: "missing error handling" and "the argument is not
// sanitized" can both be true of line 42, and promoting only the harshest would delete
// the other outright. So collapse to one entry per location, but keep every claim that
// is not a restatement of one already there. Merging is for presentation; it should
// never be the thing that loses a finding.
function claimId(f) {
  return (f.claim || '').trim().toLowerCase().replace(/\s+/g, ' ')
}

const merged = new Map()
for (const { seat, findings } of bySeat) {
  for (const f of findings) {
    const k = key(f)
    const prev = merged.get(k)
    if (prev) {
      prev.seats.push(seat)
      if (!prev.claims.has(claimId(f))) {
        prev.claims.add(claimId(f))
        prev.alsoClaimed.push({ severity: f.severity, claim: f.claim, failure: f.failure, seat })
      }
      // Keep the harshest severity anyone assigned; a seat that saw it as critical
      // saw something the others did not.
      if (RANK[f.severity] < RANK[prev.severity]) {
        prev.severity = f.severity
        prev.claim = f.claim
        prev.failure = f.failure
      }
    } else {
      merged.set(k, { ...f, seats: [seat], claims: new Set([claimId(f)]), alsoClaimed: [] })
    }
  }
}

// alsoClaimed holds every distinct claim at this location including the one promoted to
// the headline, so drop the headline from it to leave only what would have been lost.
for (const f of merged.values()) {
  f.alsoClaimed = f.alsoClaimed.filter((c) => claimId(c) !== claimId(f))
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
  diff: shape,
  // seatsRun is what reported, not what was asked for. Reporting the request would
  // credit a seat that never ran with having found nothing.
  seatsRun: ran,
  seatsFailed: failed,
  // The reason a seat was skipped is the interesting half — it is what you argue with
  // when a lens keeps missing a change you wanted it on — and it was only reaching the
  // log, not the caller.
  seatsSkipped: LENSES.filter((l) => !seats.includes(l.seat)).map((l) => ({ seat: l.seat, why: l.why })),
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
    // Other distinct defects reported at this same location. Empty for most findings.
    alsoClaimed: f.alsoClaimed,
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

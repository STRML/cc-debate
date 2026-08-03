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
// JSON, and they argue with findings. Every actual review comes from an acpx
// seat that `/debate:panel` runs between this workflow's two stages. Ten
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
  { seat: 'antigravity', why: 'a non-OpenAI model', when: (d) => !d.docsOnly },
  { seat: 'deepseek', why: 'a fourth vendor, told to argue', when: (d) => !d.docsOnly },
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

// One verdict per claim at a location, judged together but decided separately. Judging
// them together is what lets a reader collapse restatements; deciding them separately is
// what stops one refuted claim taking its neighbours with it.
const LOCATION_VERDICT = {
  type: 'object',
  required: ['claims'],
  properties: {
    claims: {
      type: 'array',
      items: {
        type: 'object',
        required: ['index', 'refuted', 'reason'],
        properties: {
          index: { type: 'integer', description: 'the claim number given in the prompt' },
          refuted: { type: 'boolean', description: 'true if this claim does not hold' },
          reason: { type: 'string' },
          severityAfter: { type: 'string', enum: ['critical', 'major', 'minor', 'nit'] },
          sameAs: {
            type: 'integer',
            description:
              'index of an earlier claim this one restates, strictly lower than index; ' +
              'omit or use -1 when it is a distinct defect that merely shares the line',
          },
        },
      },
    },
  },
}

// --- 1. classify -------------------------------------------------------------

if (STAGE === 'classify') {

phase('Classify')

// Plan mode: the seats are passed in, not sized by a diff. /debate:run with a staged
// plan resolves its panel from the config; this branch lets the report stage reuse the
// same extract/verify/rank path for both modes without measuring a diff that is not there.
if (A.plan) {
  log(`plan mode — seats: ${(A.seats || []).join(', ')}`)
  return {
    stage: 'classify',
    plan: true,
    seats: A.seats || [],
    seatsSkipped: [],
  }
}

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
// Seats the lens table asked for that this install does not own. Distinct from failed:
// nothing went wrong, they were never there to run. Collapsing the two made every panel
// on a machine without the optional seats report failures it had not had.
const notConfigured = A.seatsNotConfigured || []
const shape = A.diff || null
const seatsSkipped = A.seatsSkipped || []

for (const s of failed) log(`  ${s}: no review — not counted as run`)
for (const s of notConfigured) log(`  ${s}: not configured on this machine — never started`)

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

// Two earlier versions of this got it wrong in opposite directions, and the shape here
// is what is left after both.
//
// Keying on file:line alone and keeping the alternates in a side list lost a finding in
// both arrival orders. Keying on file:line:claim never loses one, but it only matches
// text: five seats describing one bug five ways become five records and five verifier
// calls, which puts the fan-out this workflow exists to remove back one step downstream.
//
// So group by location and let the verifier do the semantic part. Every distinct claim
// at a line survives grouping — identical wording still merges and stacks up in seats —
// and all of them go to a single verifier for that line, which judges each on its own
// and says which ones restate which. One call per location, no claim unexamined, and
// the collapsing is done by something that can read rather than by string equality.
//
// The path keeps its case. Lowercasing it merged src/Foo.js with src/foo.js on any
// case-sensitive checkout, and the survivor kept the other one's path.
function claimId(f) {
  return (f.claim || '').trim().toLowerCase().replace(/\s+/g, ' ')
}

function key(f) {
  return `${(f.file || '').trim()}:${f.line || 0}`
}

const merged = new Map()
for (const { seat, findings } of bySeat) {
  for (const f of findings) {
    const k = key(f)
    let loc = merged.get(k)
    if (!loc) {
      loc = { file: (f.file || '').trim(), line: f.line || 0, claims: [] }
      merged.set(k, loc)
    }
    const id = claimId(f)
    const same = loc.claims.find((c) => claimId(c) === id)
    if (same) {
      same.seats.push(seat)
      // Identical wording, harsher severity: a seat that saw it as critical saw
      // something the others did not. Nothing is lost — the claim text matches.
      if (RANK[f.severity] < RANK[same.severity]) {
        same.severity = f.severity
        same.failure = f.failure
      }
    } else {
      loc.claims.push({
        severity: f.severity,
        claim: f.claim,
        failure: f.failure,
        fix: f.fix,
        seats: [seat],
      })
    }
  }
}

const unique = [...merged.values()]
const claimCount = unique.reduce((n, l) => n + l.claims.length, 0)
const dupes = bySeat.reduce((n, s) => n + s.findings.length, 0) - claimCount
log(`${unique.length} location(s), ${claimCount} distinct claim(s), ${dupes} duplicate(s) collapsed`)

// --- 5. verify ---------------------------------------------------------------
//
// Of twelve seats on #22, two produced findings that were wrong and cost a read each
// to disprove. False positives scale with headcount, so they get filtered before a
// human sees them, not after. Prompted to refute: the default answer is "it holds",
// and it takes an argument to move.

phase('Verify')

const judged = await parallel(
  unique.map((loc) => () =>
    agent(
      `${loc.claims.length === 1 ? 'A reviewer claims' : `${loc.claims.length} reviewers claim`} the following about ${loc.file}:${loc.line}:

${loc.claims.map((c, i) => `  [${i}] (${c.severity}) ${c.claim}\n      It fails like this: ${c.failure}`).join('\n\n')}

Try to refute each one. Open the file at ${REPO} and read the actual code, plus whatever
callers or tests bear on it. Refute a claim if the code does not say what it says, if the
failure cannot happen for a reason the reviewer missed, if it is already handled
elsewhere, or if it describes intended behaviour.

Judge every claim separately and return one entry per index above. A claim standing or
falling says nothing about its neighbours: they are on the same line, which is not a
reason to treat them as the same defect, and an obvious wrong claim sitting beside a
subtle right one is exactly the case this must not collapse.

Where two of them genuinely are the same defect in different words, say so by setting
sameAs on the later one to the index of the earlier — a lower index only, never a
higher one, and never itself. Only for a real restatement, not for two defects that
merely share a line.

Do not refute a claim merely because it is small, or stylistic, or you would not have
raised it. Severity is not your call; truth is. If it holds, say so and leave the
severity alone unless the code shows the reviewer misjudged the impact.`,
      { label: `verify:${loc.file}:${loc.line}`, phase: 'Verify', schema: LOCATION_VERDICT },
    ).then((v) => ({ loc, verdicts: (v && v.claims) || null })),
  ),
)

// A verifier that died returns null, and parallel() yields null for a thunk that threw.
// Either way the claims at that location are unjudged — which is not the same as clean,
// so they are reported as unverified rather than dropped or assumed to hold.
const survived = []
const killed = []
const unverified = []

for (let i = 0; i < unique.length; i++) {
  const loc = unique[i]
  const result = judged[i]
  const byIndex = new Map(((result && result.verdicts) || []).map((v) => [v.index, v]))
  const kept = new Map()

  loc.claims.forEach((c, idx) => {
    const base = {
      file: loc.file,
      line: loc.line,
      severity: c.severity,
      claim: c.claim,
      failure: c.failure,
      fix: c.fix,
      foundBy: c.seats,
    }
    const v = byIndex.get(idx)
    if (!v) {
      unverified.push(base)
      return
    }
    if (v.refuted) {
      killed.push({ ...base, why: v.reason })
      return
    }
    if (v.severityAfter) base.severity = v.severityAfter
    // sameAs points backwards only, so the target is already decided when we get here.
    // If it survived, this claim folds into it and both seats get the credit; if it did
    // not, this one stands on its own rather than vanishing with it.
    const target = typeof v.sameAs === 'number' && v.sameAs >= 0 && v.sameAs < idx ? kept.get(v.sameAs) : null
    if (target) {
      target.foundBy = [...new Set([...target.foundBy, ...base.foundBy])]
      return
    }
    kept.set(idx, base)
    survived.push(base)
  })
}

log(`${survived.length} finding(s) survived, ${killed.length} refuted, ${unverified.length} unverified`)

// --- 6. rank -----------------------------------------------------------------

phase('Rank')

// severityAfter was already applied when the verdicts were read, so this only orders.
survived.sort((a, b) => {
  const s = RANK[a.severity] - RANK[b.severity]
  // A finding two seats reached independently outranks one that a single seat did,
  // at the same severity. Agreement is weak evidence, but it is evidence.
  return s !== 0 ? s : b.foundBy.length - a.foundBy.length
})

return {
  stage: 'report',
  diff: shape,
  // seatsRun is what reported, not what was asked for. Reporting the request would
  // credit a seat that never ran with having found nothing.
  seatsRun: ran,
  seatsFailed: failed,
  seatsNotConfigured: notConfigured,
  // Seats that reviewed but whose review could not be read back. Their findings are
  // absent from everything below, so the report is incomplete by exactly this much.
  seatsNotTranscribed: extractFailed,
  // The reason a seat was skipped is the interesting half — it is what you argue with
  // when a lens keeps missing a change you wanted it on. Carried through from stage one.
  seatsSkipped,
  counts: {
    raw: bySeat.reduce((n, s) => n + s.findings.length, 0),
    locations: unique.length,
    distinct: claimCount,
    survived: survived.length,
    refuted: killed.length,
    unverified: unverified.length,
  },
  findings: survived,
  refuted: killed,
  // Nobody refuted these; the verifier just never came back. They are the reviewers'
  // claims as filed, unfiltered, and they are reported as exactly that.
  unverified,
}

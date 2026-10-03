# Findings board and seat scorecard (the `debate` mod, part 2), revision 4

Status: `/debate:all` ran its 3 allowed rounds on revisions 1 to 3. Round 3: Antigravity APPROVED; Executor, Auditor,
Pentester, Simplifier and Skeptic REVISE with narrow, specific concerns. Revision 4 applies them. It has **not** been
re-reviewed by the panel; the user's review is the next gate.
Builds on the seats pane in the `debate` mod (`hooks/seats/`, branch `feat/seat-pane-mod`).

## Purpose

A `/debate:run` or `/debate:all` panel in changeset mode ends with a verified list of findings and a
per-seat record of who found what. Today that result exists as a wall of text in the conversation and a
temp task-output file. Two things are lost:

1. **Acting on the findings.** There is no list to work through, no record of which were fixed or
   declined, and nothing that survives the session.
2. **Learning from the panel.** `scripts/seat-report.sh` prints sole / corroborated / refuted / unverified
   per seat for one run and says "collect several before moving a lens". Nothing collects them.

This adds a **findings board** (act) and a **seat scorecard** (learn) to the `debate` plugin. Two decisions:
**the pipeline records, the mod reads**, and there is **one durable artifact per report**, so there is no
second file to keep consistent. `seat-report.sh` gains one mode that validates and sanitizes a report and
writes a single archive file; the mod only displays archives.

## Scope

In: changeset mode (the only mode with a report stage). Out, deliberately: plan mode (its reviews are free
text), stale-review detection and a one-button verify round, auto-fixing, verdict thresholds for seats, and
archiving Step 6.5 verification passes (Step 6.5 does not run the report stage, so it has nothing to archive).

## The contract

`commands/run.md` Step 3 (changeset mode) changes in three ways:

1. **Seat names.** The report stage reads `${WORK_DIR}/${seat}-output.md` for each seat name it is given
   (`workflows/review-panel.js:306`). Step 3 passes each Claude teammate under the stem of the file that
   delivered, `claude-<persona>-r<N>` or `claude-<persona>-r<N>-b` for a respawn, so its review is transcribed and
   the archive can check the same file. acpx seats keep their own names. A static test in
   `tests/test-references.sh` pins this wording. The scorecard folds attempt suffixes back to the lens at read time.
2. Right after the report stage returns, write the object, verbatim, to `<WORK_DIR>/report.json` (the pattern the
   classify stage uses for `panel-state.json`). The workflow has no filesystem access
   (`workflows/review-panel.js:270-272`), so the orchestrator's Write stays the source; the counts check below
   catches a re-emission slip.
3. Then run `bash ~/.claude/debate-scripts/seat-report.sh --archive "<WORK_DIR>/report.json" --round <N>`, where N is
   the revision-round counter. The `allowed-tools` of `run.md` and `all.md` (which `tests/test-references.sh`
   keeps identical) gain `Bash(bash ~/.claude/debate-scripts/seat-report.sh:*)`. On a non-zero exit the orchestrator
   relays the script's message and carries on.

`--archive` takes no id argument. It derives everything from the report's own location and refuses anything
unexpected, writing nothing:

- `report.json` is opened with `O_NOFOLLOW`; the checks (regular file, owned by the current user, at most 1 MB) run
  on the open descriptor with `fstat`, and the parent `ai-review-<8 hex>` directory is `lstat`-checked (not a
  symlink, owned by the user) and sits inside a `.tmp` directory. The 8 hex characters are the review id; the
  directory above `.tmp` is the repo root. The ownership check guards against stray files, not against a reviewer,
  which runs as the same user. `panel.json` and every `<seat>-output.md` probe get the same `O_NOFOLLOW` open.
- `--round` must match `^[1-9][0-9]{0,2}$`.

### Where the archive lives, and why

`~/.acpx/debate-reports/`. The plugin already writes under `~/.acpx` (`Write(~/.acpx/**)` is in `run.md` and
`all.md` `allowed-tools` and in `/debate:setup`'s allowlist), and `commands/setup.md:256` says the sandbox blocks
writes under `~/.claude`, which would make `--archive` a silent no-op on every sandboxed install. A failed write
prints that it needs the `Write(~/.acpx/**)` entry. `--archive` is never run unsandboxed. Nothing in `setup.md` or
the printed snippet changes.

The directory is reviewer-writable, since reviewers run as the same user inside the same allowlist. So the
writer is not the only line of defence; see "Read-time guard".

### The archive file

`<id>-r<N>.json`, written with `tempfile.mkstemp` in the same directory (exclusive create, 0600) and moved into
place with `os.replace`: one file appears whole or not at all, and a retry rewrites it. Before writing, the
directory is `lstat`-checked (refuse a symlink or a foreign owner) and `chmod`ed 0700. The newest 300 by mtime are
kept; pruning touches only regular, non-symlink files whose names match `^[0-9a-f]{8}-r[1-9][0-9]{0,2}\.json$`.
Serialization uses `allow_nan=False`.

```
{ v: 1,
  meta:      { id, round, ts, root },
  seatState: { <seat>: "reported"|"failed"|"not-configured"|"unreadable" },
  seatMeta:  { <seat>: { model, effort, est_cost } },
  report:    { diff, seatsRun[], seatsFailed[], seatsNotConfigured[], seatsNotTranscribed[], seatsSkipped[],
               counts, findings[], refuted[], unverified[] } }
```

It holds finding text, which can quote the user's code. It stays on the machine at 0600, beside session
transcripts that already hold far more; it leaves only through the user's own button presses.

### Report shape, validation, sanitizing

The workflow's returned object: `diff` (may be null), the seat lists (names; `seatsSkipped` entries are objects
`{ seat, why }`), `counts`, and `findings[]`, `refuted[]` (with `why`), `unverified[]`, each
`{ file, line, severity: "critical"|"major"|"minor"|"nit", claim, failure, fix?, foundBy[] }`. `fix` is optional
and `line` is 0 when a finding has none.

`--archive` parses with `parse_constant` rejecting `NaN` and `Infinity`, and rejects the report (writing nothing)
unless all of these hold:

- `counts.survived`, `.refuted` and `.unverified` equal the three array lengths (the orchestrator is a model
  re-emitting JSON);
- no array has more than 200 entries (reject, not truncate, so `counts` and the arrays never disagree);
- every seat name (all `seats*` lists, `seatsSkipped[].seat`, `foundBy`) matches `^[a-z0-9][a-z0-9._-]{0,63}$` and
  has no `..`, since names become paths and object keys;
- every `foundBy` name is in `seatsRun`;
- `line` is `type(x) is int` and >= 0 (a boolean is not a line).

Then it sanitizes:

- Every text field is capped at 2,000 code points, `model` at 64, `effort` at 16. Strip Unicode categories Cc, Cf,
  Cs, Zl and Zp except newline and tab (C0 and C1 controls, bidi overrides, zero-width characters, lone surrogates,
  U+2028 and U+2029).
- `file`: `os.path.normpath` first. An absolute path with `os.path.commonpath([root, p]) == root` becomes
  repo-relative; an absolute path outside the root is "(outside repo)"; a result containing `..` is "(unsafe
  path)"; an empty one is "(unknown file)".
- `seatMeta` comes from `panel.json` for seats the selector assigned (`model_id`, `effective_effort`,
  `effective_cost`), type-checked (strings capped; `est_cost` a finite number >= 0, rounded to 4 decimals, else
  null); seats outside the manifest get nulls. `est_cost` is the registry's estimate scaled by an effort
  multiplier, not measured spend.
- **Seat state**, in this precedence: in `seatsNotTranscribed` is `unreadable`; else in `seatsNotConfigured` is
  `not-configured`; else in `seatsFailed` or not in `seatsRun` is `failed`; else (a seat in `seatsRun`) its
  `<seat>-output.md` missing, empty or a symlink is `unreadable`; else `reported`. The file check applies only to
  seats that ran, so a failed or never-started seat keeps its state. The first three steps are
  `seat-report.sh:91-96`; the file check is the new part, and it is how a seat whose review was never read stays
  distinguishable from one that found nothing. `seatsSkipped` seats are not recorded.

## Read-time guard (the mod)

The pipeline sanitizes once, but a reviewer can write a file straight into `~/.acpx/debate-reports/`, so the mod
guards the places untrusted text reaches a person or a prompt. It does not re-validate the whole archive:

- It skips any archive file larger than 2 MB (`fs.list` reports `size`) and any that fails JSON parse or a minimal
  shape check (arrays of objects with string fields), reporting "could not be read".
- One small `cleanText` (strip Cc, Cf, Cs, Zl, Zp except newline and tab; cap at 2,000 code points) and one
  `safeFile` (the same `file` rules) are applied to every field when it is drawn and again when a button builds a
  prompt. Both are pure and tested.
- Seat names that fail the writer's regex are dropped. Aggregates are built in a `Map`, never as `acc[name]`,
  so a seat named `__proto__` cannot reach `Object.prototype`.

## Findings board (`/debate-board`)

- **Root.** The mod resolves the repo root the way the writer does: `git rev-parse --show-toplevel` run through
  `$.process.run` (argv, no shell) from `$.session.cwd()`, cached in an atom and refreshed on `session.start`. A
  linked worktree (this user's default) is its own toplevel, equal to the `meta.root` its panel recorded;
  `$.session.repo().root`, which names the main working tree, would not match, and a session started in a
  subdirectory is handled by the git call. If git fails, the board says so.
- The board lists `~/.acpx/debate-reports` (the directory comes from `$.env.get('HOME')`, since `$.fs` does not
  expand `~`), considers only names matching the archive pattern, and shows the newest whose `meta.root` equals
  that root, never another repo's (a finding's `file` steers an edit). No path is built from typed input and there
  is no id argument. The empty state names the root it looked for: "no panel report for `<root>`".
- A pane lists survivors by severity (critical, major, minor, nit), each with `file:line` (the bare file when
  `line` is 0), claim, failure and fix. Unverified ones are labelled; refuted ones sit collapsed with the
  verifier's `why`. The header says "panel `<id>`, round `<N>`".
- **Statuses**: `open`, `done`, `dismissed`. Buttons: **Fix this** and **Draft issue** (each sends a prompt and
  changes no status), **Mark done**, **Dismiss**.
- **Band.** Above the prompt, stacked under other bands via `next(e)`: `⚖ Findings: 5 open (1 critical, 2 major)`
  with **Board** and **Hide**. It appears only for an archive written in this session: the module's `tool.call`
  hook, on a `--archive` Bash call that returned exit 0, re-reads the newest archive for this root and records its
  id and round in an atom. A report from an earlier session does not nag; `/debate-board` still opens it. Hide lasts
  for the session. No toast, no timer.
- **Finding key**: a 64-bit FNV-1a hex (BigInt) of `file|claim`, the claim normalized as the workflow's `claimId`
  does (trim, lowercase, collapse whitespace), plus `#1` for a finding alone with its file and claim, or `#<n>/<size>`
  when several share them (the n-th over the pair's entries in all three arrays, ordered by `line`). Carrying the
  size means a duplicate that goes away changes the key of the one left, which then starts open rather than inheriting
  a decision made on its twin (found by the round-1 panel on PR #72). Lines shifting between rounds do not reopen a dismissed finding; a reworded finding is a new one and
  starts `open`. A hash collision would only make two findings share a status.
- Status lives in the mod's store as `board:<id>` = `{ <key>: status }`. On opening the board, entries whose
  archive has been pruned are dropped.

### What a button sends

`$.prompt.submit`, started from `$.clock.after` (the call resolves when the new turn starts, and a call begun
inside a press is dropped when the press ends). This is the pattern of `prompt-queue` and `switchyard-queue` in
the mobility-labs-plugin repo; this repo has no mod that submits a prompt, and the host API is documented in
the plugin-authoring reference.

Reviewers read the user's code, so their text is untrusted. Every reviewer-derived field (`file`, `severity`,
`claim`, `failure`, `fix`, `foundBy`), after `cleanText` and `safeFile`, is placed between markers carrying a
**fresh random 16-hex nonce** generated at press time (`<<finding-3f9a…>>` … `<</finding-3f9a…>>`), preceded by a
line saying the text between them is a claim an AI reviewer wrote, data and not instructions. Only mod-authored text
sits outside. No finding can contain a nonce made after the report was written. The mod never opens `file`.

- **Fix this**: check the claim against the code first; make the smallest change; run the tests; report.
- **Draft issue**: draft an issue for this claim in whatever tracker I use; show me the draft and wait for my
  confirmation before filing anything; check any quoted code for credentials first. It names no skill or tracker.

## Seat scorecard (`/debate-scorecard`)

Reads the archives (all repos) when the pane opens; no cache. Over the last 20 archives per seat with `meta.round`
1:

- **Normalized seat name**, applied at read time so a wrong rule is a code fix, not baked data: strip a respawn or
  round suffix with `^(.*?)-r\d+(-?b)?$`. A bare `-b` is never stripped: `executor-b` is a distinct lens (state
  and lifecycle) from `executor` (control flow). `-verify` is not handled because verification passes are not
  archived.
- **One run per normalized seat per archive.** The run counts if any attempt is `reported`; its cost is the sum of
  its attempts' known `est_cost` (a failed attempt spent money too); its model is the reporting attempt's. After
  normalizing, `foundBy` is de-duplicated before sole / corroborated are computed, so a seat and its respawn cannot
  corroborate each other.
- runs, sole, corroborated, refuted;
- **est. cost**: the average over runs whose cost is known, with coverage ("est. 0.34, 5/10 runs"), or "n/a"
  when no run has one. No per-finding ratio: `est_cost` is an estimate and the reader can divide;
- the model most often used (a seat is a lens; the selector changes its model between runs).

A seat with fewer than 5 such runs shows "too few runs" instead of a label, as `seat-report.sh` advises. Round 1
is the independent judgment; later rounds re-review fixed code, so counting them would inflate sole findings.
A lens the selector rarely picks may stay under 5 by design. No thresholds, no recommendations.

## Structure

A plugin allows one hooks module (`plugin-authoring/reference.md:13`: "one path"). Implementation found two more host
rules (the host's static check of a module): `$` is followed only into functions declared in the same file, never across
an import, and `session.start` may be registered once per module. So **all hook code is one file, `hooks/register.tsx`**
(the seat pane and the board; `hooks/hooks.json` `modules` points at it), and only pure code is split out. A composer
over two registering parts, as revision 4 described, does not load.

- `hooks/report/lib.ts`: pure functions: the shape guard, `cleanText`, `safeFile`, the finding key, board
  counts, nonce framing, normalization and aggregation.
- `hooks/register.tsx`: the seat pane and band, and the board's band, panes, commands, root atom and `tool.call` hook
  (registered with `{ tool: 'Bash' }`, since the seats part's `tool.call` has no matcher).
- `scripts/seat-report.sh`: the `--archive` mode (python) and its header usage.
- Hardening of the seats part: `findWorkDir` accepts only a path whose last segment matches
  `ai-review-[0-9a-f]{8}`, under a `.tmp` segment, with no `..`, the same pattern `--archive` requires.
- Surfaces to update: `commands/run.md` Step 3 and `allowed-tools`; `commands/all.md` `allowed-tools`;
  `hooks/hooks.json` `description` and `modules`; `README.md` (the mod section is renamed from "the
  `debate-seats` mod" to cover seats, board and scorecard); `CHANGELOG.md`; `codemaps/backend.md` (the
  `seat-report.sh` row) and `codemaps/data.md` (`report.json` in the work-dir tree, and the new
  `~/.acpx/debate-reports/<id>-r<N>.json` with its schema); `tests/test-references.sh` (the Step 3 wording);
  the labels in `tests/test-seats-mod.sh` and `tests/run-all.sh`. `commands/setup.md` and the setup snippet do not
  change: `Write(~/.acpx/**)` is already there.

## Error handling

No archive for this root: "no panel report for `<root>`; changeset-mode panels save one". A file that fails the
size, parse or shape guard: "could not be read", nothing drawn. `panel.json` missing: that run's cost is null. A
rejected or failed `--archive`: the orchestrator relays why, and the board and scorecard are unchanged. Hot
reload: state lives in atoms and the store; the module keeps no timers or mtimes.

## Testing

- **Always-run bash**, in a new `tests/test-seat-report-archive.sh` registered in `tests/run-all.sh` (nothing
  tests `seat-report.sh` today; `claude plugin test` skips on older builds). Static: `run.md` and `all.md` name
  `report.json` and `seat-report.sh --archive` at Step 3 and in `allowed-tools`, and Step 3 passes Claude teammates
  by file stem. `--archive` accepts a nit, a null `diff`, `line: 0`, no `fix`, `seatsSkipped` objects. It rejects,
  writing **no file**: counts that disagree with array lengths, a 201-entry array, a `foundBy` outside
  `seatsRun`, a seat name `../x` or `__proto__`, a report whose directory is not `ai-review-<8 hex>` under
  `.tmp`, a symlinked report or a symlinked `ai-review-*` directory, an input over 1 MB, `NaN`/`Infinity`,
  `line: true`, a non-integer or traversal `--round`. It sanitizes an absolute path under the root, one outside
  it, `<root>/../../etc/x`, `<root>-evil/x`, an empty `file`, `..`, bidi, zero-width and lone-surrogate characters,
  U+2028, and over-cap text (including a multibyte character at the cap). Seat state: a seat with a missing
  `<seat>-output.md` is `unreadable`, as is one in `seatsNotTranscribed`; a failed seat or a not-configured seat
  with no output file **keeps** its state; a symlinked output file is `unreadable`. Archive hygiene: re-running
  rewrites the same file; the archive is 0600 in a 0700 directory; a symlinked archive directory is refused;
  pruning keeps 300 and only touches matching regular files; a failed write names `Write(~/.acpx/**)`.
- **Plugin tests**: lib (shape guard, `cleanText`, `safeFile`, finding key stability under whitespace, case and
  shifted lines, `#n` stable when two same-pair findings reorder, counts, nonce framing covering every field,
  normalization over `executor`, `executor-b`, `claude-opus-skeptic-r1`, `-r1-b` and `-r1b`, one run per
  normalized seat when two attempts share an archive, de-duplication, aggregation with mixed known and unknown
  costs, a seat named `__proto__`, the round-1 filter) and hooks with a mocked host (the root comes from the git
  call, with a session in a subdirectory and with a linked worktree whose `repo().root` differs; the directory
  handed to `fs.list` is absolute; the board shows only this root's archive and ignores a newer one from another
  repo or a sibling-prefix repo; a hand-planted archive with a bidi claim, a `..` file and an oversized file
  renders sanitized or is skipped; each group renders; each button sends the right prompt or sets the right
  status; statuses persist across a reload and are dropped with their archive; the board renders when the work dir
  is gone; the band shows only after a `--archive` call that returned 0 in this session, stacks with a stand-in
  plugin and hides on Hide).

## Risks and limits

- The orchestrator may skip the Step 3 instructions (the static tests and the runtime message mitigate it).
- `report.json` and the archive directory sit in trees reviewers can write, and in `/debate:all` Claude teammates
  stay alive until Step 10. A forged or swapped file passes the writer's ownership check, since it is the same
  user. The writer's validation, the mod's read-time guard and the fact that every action is a deliberate button
  press bound the effect to forged text on screen.
- A button hands model-written text to the session. The nonce framing is a mitigation, not a guarantee, and the
  session's own permission mode still applies.
- One run is one data point; the scorecard shows data, not verdicts. Round 1 only, by design.
- Changeset mode only. Upstream (STRML/cc-debate) must accept the `run.md` steps, the script mode and the mod;
  until then this lives on the local branch `feat/seat-pane-mod`.

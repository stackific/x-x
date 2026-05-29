# Skill-eval prompts (manual) + contradiction cases

This doc is for two audiences:

- **People driving `/scope` and `/ship` by hand** — paste the prompts in
  the first half into any agent that has the bundled skills installed
  (Anthropic Claude Code, Codex, Pi, omp, Cline, Copilot CLI, OpenCode), then
  watch the skill execute the same shapes the `skills-evals/` test
  suite enforces in CI.
- **Reviewers inspecting a work-item tree for semantic problems** — the
  second half lists the kinds of contradictions `stax work-items lint` does
  NOT catch (it's a structural linter, not a meaning checker) and the
  `/scope` skill's design relies on a human noticing.

## Part 1 — Manual eval prompts

Each block is a single agent turn. Where two prompts are listed, run
them one after the other in the **same** project workspace (they share
state — the second prompt's behavior depends on the first work item
existing).

Every prompt assumes the workspace has been initialised with
`stax init` (so `.stax/_config.lock`, `.stax/_data_systems.yaml`, and
the bundled skills are all in place). If you want the contradiction
checks below to have meaningful overlap, run the prompts inside a copy
of `.stax.example/`.

### Prompt 1 — One-shot scope (todo app)

> `/scope build a single HTML and localStorage-based todo list app`

**Source:** `skills-evals/tests/test_claude_todo.py` (and the matching
`test_cline_todo.py`, `test_omp_todo.py`, `test_opencode_todo.py`,
`test_pi_todo.py`, `test_copilot_todo.py`).

**What to watch for:**

- A sub-plan is presented and ends with the literal sentence
  `Reply yes to proceed, or tell me what to change.` (Appendix A,
  approval discipline).
- After `yes`, exactly one file appears under `.stax/<prefix>-<slug>.md`
  with title-first / created-last frontmatter and the three required
  body sections (`## Goal`, `## Approach`, `## Tasks`).
- `stax work-items lint` exits 0.
- The skill stops. It does NOT chain into `/ship` (forbidden by the
  identity rules), and zero non-work-item files were written.

### Prompt 2 — Scope, then ship

```
/scope build a single HTML and localStorage-based todo list app
```

then in the next turn:

```
/ship
```

**Source:** `skills-evals/tests/test_*_todo.py` second-half (the
`/ship` invocation).

**What to watch for:**

- `/ship` enumerates the work queue with `stax work-items list --status valid
  --order=asc` and proceeds straight into execution **without** a
  "found N work items, proceed?" prompt (Step 2→3 has no gap).
- Every EARS checkbox in `## Tasks` flips from `[ ]` to `[x]` only
  after the corresponding artifact actually exists on disk.
- The work item stays `status: valid`. `/ship` does NOT flip the status to
  `superseded` or `deprecated` on a happy-path execution.

### Prompt 3 — Extends pair (both stay valid)

Two turns in the same workspace:

```
/scope build a single HTML and localStorage-based todo list app
```

```
/scope add a 'clear all completed' button to the existing todo list
app. This is a follow-up work item that extends the previous one — both
work items should remain valid; do not supersede.
```

**Source:** `skills-evals/tests/test_claude_plan_extends.py` (and the
sister `test_*_plan_extends.py` for other backends).

**What to watch for:**

- Work-item B's frontmatter has `extends: [<work-item-A-slug>]` between the
  `systems:` and `created:` keys.
- Work-item A's frontmatter has `extended_by: [<work-item-B-slug>]` (the skill
  edited the predecessor as a side effect of writing B, per Step 3).
- Both files keep `status: valid`. Extends is a forward pointer, not a
  state change.
- `stax work-items lint` exits 0 — its bidirectional-link check is what
  guarantees both sides were written.

### Prompt 4 — Supersedes pair (predecessor retires on /ship)

```
/scope build a single HTML and localStorage-based todo list app
```

```
/ship
```

```
/scope replace the previous todo list app with a single-page HTML
reminders app backed by localStorage. The user can add a reminder,
enable or disable a reminder (check on/off behavior similar to the
todo app's checkbox), and delete a reminder. When a reminder's time
arrives, the app must display a notification div alerting the user.
This work item SUPERSEDES the previous todo list work item — mark it accordingly.
```

```
/ship
```

**Source:** `skills-evals/tests/test_pi_reminders_supersedes_todo.py`
and `test_cline_reminders_supersedes_todo.py`.

**What to watch for:**

- After the second `/scope`, the new work item has `supersedes:
  [<work-item-A-slug>]` and the predecessor still reads `status: valid`
  (the flip is `/ship`'s job, not `/scope`'s — Step 3 / identity
  rule #3).
- After the second `/ship`, the predecessor's `status:` is now
  `superseded` AND its `superseded_by:` array contains the successor's
  slug.
- If the new work item's `## Tasks` includes cleanup criteria (per the
  "Supersedes may require cleanup criteria" rule in Step 3),
  artifacts from the predecessor are gone from disk.

### Prompt 5 — Stream-json smoke

> `Respond with the single word: ok`

**Source:** `skills-evals/tests/test_claude_stream_json_smoke.py`
(and `test_cline_stream_smoke.py`, `test_omp_stream_smoke.py`, etc.)

**Why it exists:** confirms the agent harness can produce a clean
stream-JSON transcript end-to-end without any skill involvement. Use
this to verify a fresh install before running any of the
work-item-mechanics prompts above. If this fails, the higher-level prompts
will fail for harness reasons, not skill reasons.

### Prompt 6 — Hook firing (Claude only)

Drive any one-shot Claude session that triggers a `Write` tool call
(e.g. asking it to create a single file), then verify that:

- `<HOME>/.claude/settings.json` (user scope) or
  `<workspace>/.claude/settings.json` (project scope) contains the
  bundled hook records under `hooks.PostToolUse` and `hooks.Stop`.
- After the session ends, both the PostToolUse hook (gated on a
  `Write|Edit|MultiEdit` matcher) AND the Stop hook ran. The
  `skills-evals` test does this by patching each hook's `command:`
  field to `touch <marker-file>` and checking that both markers
  exist on disk after the run.

**Source:** `skills-evals/tests/test_claude_hooks_fire.py`.

**What to watch for:** a regression here usually means the deep-merge
in `stax init` landed JSON in the wrong shape, or the matcher
expression in `agents/claude/settings.json` no longer matches Claude's
tool names.

## Part 2 — Contradictions the lint won't catch

`stax work-items lint` enforces **structural** invariants: filename pattern,
line cap, frontmatter ordering, bidirectional links, slug resolution,
system membership, EARS-subject ↔ `systems:` set equality, required
sections. It does NOT enforce **semantic** invariants — two work items can
each pass lint while making contradictory `[x]` claims about the same
system. The `/scope` skill's Appendix C says the source of truth for
"what's true now" is the union of `[x]` criteria across `status: valid`
work items, so any contradiction in that union is a real bug the human
review pass has to catch.

The patterns below are the recurring shapes worth scanning for. Each
one is followed by a concrete sample that would land cleanly through
`stax work-items lint` but is wrong.

### 2.1 Mutually exclusive responses to the same trigger

Two valid work items, same system, same event, contradictory `shall` clauses.

> **Generic shape:**
> - Work-item A `[x]` — `When <trigger>, the <System> shall <response-A>.`
> - Work-item B `[x]` — `When <trigger>, the <System> shall <response-B>.`
>
> Where `<response-A>` and `<response-B>` are mutually exclusive (e.g.
> "retry" vs "halt", "send" vs "drop", "include" vs "omit"). Lint
> sees two well-formed EARS criteria; review has to notice the trigger
> overlap.

### 2.2 Same-window contradiction (rate-limit, retention, dedup, etc.)

Two valid work items on the same system declare different numeric windows
for what is essentially the same policy.

> **Generic shape:**
> - Work-item A `[x]` — `the <System> shall <verb> within <N> minutes.`
> - Work-item B `[x]` — `the <System> shall <verb> within <M> minutes.`
>
> Where neither work item supersedes the other and `N ≠ M`. The newer work item
> may have meant to refine the older but forgot the `supersedes:` or
> `extends:` link.

### 2.3 Retain-vs-purge contradiction

One work item establishes a retention/archive rule; a later valid work item
deletes or purges the same data on a shorter cycle.

> **Generic shape:**
> - Work-item A `[x]` — `the <System> shall retain <data> for <N> days.`
> - Work-item B `[x]` — `the <System> shall purge <data> after <M> days.`
>
> Where `M < N` and Work-item B doesn't carve out an exception. Either
> Work-item A is stale (should be `superseded`) or Work-item B has the wrong
> window — both are reviewable mistakes.

### 2.4 Stale-foundation extends

A work item whose `extends:` array points at a predecessor whose `status:`
is `superseded` or `deprecated`. The bidirectional link still passes
lint (the slugs resolve), but the extender is building on a
foundation that no longer reflects current truth.

> **Generic shape:**
> - Predecessor: `status: superseded`, `extended_by: [<extender>]`
> - Extender: `status: valid`, `extends: [<predecessor>]`
>
> The extender's `[x]` criteria are now anchored to a retired
> contract. Either the extender should be re-pointed at the
> successor, or it should itself be `superseded`.

### 2.5 Supersedes without cleanup

A work item with `supersedes:` whose `## Tasks` never mentions the
predecessor's on-disk artifacts. The successor's claims are valid in
isolation but the predecessor's files/endpoints/rows are still on
disk, so the workspace mixes "old way" and "new way" in production.

> **Generic shape:**
> - Predecessor `[x]` — `the <System> shall write <path-or-row>.`
> - Successor: `supersedes: [<predecessor>]` with `## Tasks` that
>   doesn't include `the <System> shall remove <path-or-row>.`
>
> Appendix A in `agents/skills/scope/SKILL.md` calls this out
> explicitly ("Supersedes may require cleanup criteria"); the
> reviewer has to notice when the cleanup task was skipped.

### 2.6 EARS-subject ambiguity disguised as two systems

A work item splits one logical actor into two registry entries to satisfy
the "exactly one named system per criterion" rule, when really one
system owns both behaviors. The split looks fine to lint (both
registry ids exist, both systems get tasks) but creates two source-of-
truth surfaces for what is functionally one component.

> **Generic shape:** a work item declares `systems: [api-gateway,
> api-rate-limiter]` where `api-rate-limiter` is just a module inside
> the gateway and has no independent deployable boundary. Future
> work items then split criteria across the two and the source-of-truth
> union becomes inconsistent.

## Part 3 — Contradictions seeded into .stax.example

These are concrete contradictions a reviewer could detect against the
actual scopes in `.stax.example/`. None of them are present in the
shipped data (the tree is currently coherent — `stax work-items lint`
passes 106/106). Each entry is a **hypothetical** new work item you could
draft and present as a sub-plan; the reviewer's job is to recognise
the conflict and push back before approval.

To exercise these manually: copy `.stax.example/` to a scratch
project, write the hypothetical work item into `.stax/`, then ask `/scope`
to plan a follow-up that touches the same system — a competent run
should surface the discrepancy during Step 2a's "find potential
discrepancies" check.

### Case A — Token-expiry contradiction (Auth Service)

The `.stax.example/` tree already declares:

- **0014 expire-refresh-tokens-after-seven-days-of-inactivity** —
  `the Auth Service shall expire refresh tokens after 7 days of
  inactivity.`

Hypothetical contradicting work item:

> **Proposed:** `0107 raise refresh token inactivity window to 30
> days` — `the Auth Service shall expire refresh tokens after 30 days
> of inactivity.`

**Why it's a contradiction:** both work items claim to set the inactivity
expiry window on the same system; they can't both be `[x]` at the
same time without one superseding the other. The proposed work item
should be written as `supersedes: [0014-expire-refresh-tokens-after-
seven-days-of-inactivity]`, not as a standalone valid work item.

### Case B — Dedup-window contradiction (Notification Bus)

The shipped data declares:

- **0090 suppress-duplicate-notifications-within-five-minutes** —
  `the Notification Bus shall suppress duplicates within 5 minutes.`
  (Now `extended_by: [0104-add-configurable-dedup-window-per-channel]`.)
- **0104 add-configurable-dedup-window-per-channel** — extends 0090,
  makes the window configurable, **defaults to 5 minutes when unset**.

Hypothetical contradicting work item:

> **Proposed:** `0108 widen marketing dedup window to one hour` —
> `the Notification Bus shall suppress marketing duplicates within
> 1 hour.`

**Why it's a contradiction:** the proposed work item claims a 1-hour
window on a sub-channel without going through the configurable
mechanism 0104 established. Either it should `extends:
[0104-add-configurable-dedup-window-per-channel]` and frame the
1-hour window as a channel config, or it should explicitly supersede
0090's 5-minute default for the marketing channel. Standalone, it's
two contradictory dedup windows on the same system.

### Case C — Archive-vs-purge contradiction (Ingest Pipeline)

The shipped data declares:

- **0056 compact-event-logs-older-than-seven-days** — `the Ingest
  Pipeline shall compact event logs older than 7 days.`
- **0064 archive-raw-events-to-cold-storage-after-ninety-days** —
  `the Ingest Pipeline shall archive raw events to cold storage after
  90 days.`

Hypothetical contradicting work item:

> **Proposed:** `0109 purge raw events after thirty days to cut
> storage cost` — `the Ingest Pipeline shall purge raw events after
> 30 days.`

**Why it's a contradiction:** 0064 says raw events go to cold storage
at 90 days; the proposed work item purges them at 30 days. The 30-day
purge happens before the 90-day archive can fire, so 0064's `[x]` is
no longer satisfiable in production. Either 0064 needs `superseded_by:
[0109-…]` or 0109 needs `extends: [0064-…]` with a carve-out.

### Case D — Auto-cancel vs manual-review contradiction (Billing)

The shipped data declares:

- **0024 auto-cancel-subscriptions-after-three-failed-payments** —
  `When 3 consecutive payments fail, the Billing shall auto-cancel
  the subscription.`

Hypothetical contradicting work item:

> **Proposed:** `0110 require manual review before any cancellation`
> — `Before the Billing cancels a subscription, the Billing shall
> require a manual review.`

**Why it's a contradiction:** 0024 says "auto-cancel" (no human);
0110 says "manual review" (requires human). Lint sees two well-formed
EARS criteria; review has to notice the policies are mutually
exclusive — either supersede 0024 or carve out the "after N failed
payments" path as a manual-review exception.

### Case E — Quiet-hours carve-out gap (Notification Bus)

The shipped data declares:

- **0089 add-quiet-hours-per-recipient-based-on-timezone** — `While a
  recipient is inside quiet hours, the Notification Bus shall buffer
  non-critical messages.`
- **0085 add-sms-delivery-channel-for-two-factor-codes** — sends 2FA
  codes by SMS.

Hypothetical contradicting work item:

> **Proposed:** `0111 always deliver 2FA codes within thirty seconds`
> — `When a 2FA challenge starts, the Notification Bus shall deliver
> the SMS within 30 seconds.`

**Why it's a contradiction:** 0089 buffers "non-critical" messages
during quiet hours but never defines "critical." 0111's 30-second
guarantee is incompatible with 0089's buffering unless 2FA is
explicitly carved out as critical. A competent reviewer should push
back and ask: "is 2FA in the 'critical' carve-out 0089 didn't
specify? If so, supersede 0089 with a version that names the carve-
out; if not, soften 0111's `shall` to a target." Either way, the two
work items as drafted can't both be `[x]` in production.

### Case F — Cleanup-gap supersede (Billing, references our existing data)

The shipped data already supersedes the right way: **0020 generate-
pdf-invoices-for-annual-subscriptions** is `superseded_by: [0101-add-
stripe-hosted-invoice-pages]`. Verify the cleanup by reading 0101's
`## Tasks`:

> 0101's tasks today are:
> - `When an invoice is finalised, the Billing shall record the
>   Stripe hosted-invoice URL.`
> - `When a renewal email is sent, the Billing shall include the
>   hosted-invoice URL instead of an attachment.`

Hypothetical regression: imagine an alternate 0101 that omits the
"instead of an attachment" carve-out:

> **Proposed alt-0101:** keeps both lines but drops the "instead of
> an attachment" clause from the second task.

**Why it's a contradiction:** 0020's `[x]` says the renewal email
gets a PDF attachment; the alt-0101 still emits the PDF AND the
hosted URL, leaving 0020's behavior in production. The cleanup
clause in the real 0101 is what makes the supersede coherent. The
sample is correct as written; this case is here so reviewers can spot
the same pattern when a future supersede forgets the cleanup.

## Part 4 — Coverage gaps the SKILL file enforces but lint doesn't

For completeness, here's the set of `/scope` rules that no automated
check can catch — every one of them is enforced only by review or by
the skill's own self-discipline mid-run:

- **`/scope` MUST NOT invoke `/ship`** (Identity rule #4). If `/scope`
  chains into the executor, the work item-only contract is broken;
  detectable only by reading the agent transcript.
- **`/scope` MUST NOT flip checkboxes** (Identity rule #2). A
  `[x]` set during `/scope` instead of `/ship` is a violation;
  detectable by comparing the work-item file before and after `/scope`.
- **`/scope` MUST NOT touch a predecessor's `status:`** when adding a
  `supersedes:` link (Identity rule #3 + Step 3). The status flip is
  `/ship`'s job; a `/scope` that flips it eagerly creates a
  predecessor that's "retired" without its successor having executed.
- **Approach bullets without a covering Task** (Step 3 hard rules).
  Lint accepts a work item with rich `## Approach` and an empty `## Tasks`,
  but the SKILL says every Approach deliverable must have an EARS
  task. The lint check would need to parse Approach intent — too
  fuzzy.
- **EARS criteria with vague responses** (Appendix B hard rule #6).
  "the Auth Service shall feel modern" passes lint (it's well-formed
  EARS); review has to push back on "feel modern" as non-observable.
- **System granularity drift** (Appendix C — "be one level more
  granular"). Picking the root API project as the system for every
  work item passes lint but yields work items that are too umbrella-y to ship.

A future addition to `stax work-items lint` could catch some of these
(e.g. cross-work-item overlap on the same system + similar trigger), but
most of this list is genuinely semantic and belongs in the human
review loop the work-item-first protocol exists to enforce.

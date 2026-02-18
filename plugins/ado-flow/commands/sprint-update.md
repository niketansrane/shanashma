---
name: adoflow:sprint-update
description: Auto-classify sprint work items using merged/open PRs, bulk-confirm updates, flag blockers, move items to next sprint, and generate a copy-paste standup summary
argument-hint: "[update my sprint items | quick sprint update | sprint standup | move #1234 to next sprint]"
---

# Azure DevOps Sprint Update

Keep your sprint board accurate in under a minute. Auto-classifies work items by PR activity, bulk-confirms the obvious ones, walks through only ambiguous items, and generates a standup summary.

## Arguments

<user_request> $ARGUMENTS </user_request>

**If the request above is empty, proceed with the default workflow:** auto-classify and update all active sprint work items.

## Prerequisites

Load the shared configuration by following the setup instructions in the `ado-flow` skill's "First-Time Setup" section.

```bash
cat ~/.config/ado-flow/config.json 2>/dev/null
```

If no config exists, follow the `ado-flow` skill to run first-time setup. Once config is loaded, you will have: `{ORG}`, `{WORK_ITEM_PROJECT}`, `{PR_PROJECT}`.

Resolve the user's identity:

```bash
az account show --query "user.name" -o tsv
```

Store as `{USER_EMAIL}`. **Validate it contains `@`.** If it returns a GUID or display name, ask the user for their email.

---

## Workflow

### Step 1: Detect Sprint Context (run 1a, 1b, and 1c in parallel)

#### 1a: Current Sprint Iteration Path

Fetch the user's recent work items to determine the current sprint, following the "Detecting Area Path and Iteration Path from Recent Work Items" section in the shared skill.

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me ORDER BY [System.ChangedDate] DESC" \
  -o json
```

Identify the most recent non-backlog, non-root iteration path. Store as `{CURRENT_ITERATION}`.

**If zero results with `@me`**, retry with `{USER_EMAIL}` in the `WHERE` clause. If still nothing, ask the user for their iteration path.

#### 1b: Detect Process Template States

Detect valid states for work items. Try the CLI first:

```bash
az boards work-item type list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  -o json
```

If that command is not available or fails, fall back to the REST API:

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{WORK_ITEM_PROJECT}/_apis/wit/workitemtypes/Task/states?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json
```

From the response, classify states using the `stateCategory` field (not the display name):
- `{STATE_NOT_STARTED}` — category = `Proposed`
- `{STATE_IN_PROGRESS}` — category = `InProgress`
- `{STATE_DONE}` — category = `Resolved` or `Completed`
- `{STATE_REMOVED}` — category = `Removed` (may not exist in all templates)

**Also query states for other work item types** present in the sprint (Bug, User Story, PBI) if they differ from Task. Cache per type.

Build a dynamic exclusion list of all terminal state names for use in Step 2's WIQL.

#### 1c: Fetch Sprint Dates

```bash
az boards iteration project show \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --path "{CURRENT_ITERATION}" \
  -o json
```

Store `{SPRINT_START_DATE}` and `{SPRINT_END_DATE}` for carryover detection and next-sprint logic.

---

### Step 2: Fetch Active Work Items

Query all work items assigned to the user in the current sprint that are not yet done. Format terminal states as single-quoted, comma-separated values for WIQL — e.g., `NOT IN ('Done', 'Closed', 'Removed')`.

**WIQL escaping:** If `{CURRENT_ITERATION}` contains single quotes, escape them by doubling: `'` → `''`.

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id] FROM workitems WHERE [System.AssignedTo] = @me AND [System.IterationPath] = '{CURRENT_ITERATION}' AND [System.State] NOT IN ({DYNAMIC_TERMINAL_STATES}) ORDER BY [System.WorkItemType] ASC" \
  -o json
```

**If zero results with `@me`**, retry with `{USER_EMAIL}`. If still zero, output "No active items in `{CURRENT_ITERATION}`. Sprint board looks clean!" and skip to Step 6 (standup with empty content).

The query returns work item IDs only. Fetch full field values. For 10+ items, use the batch API:

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WORK_ITEM_PROJECT}/_apis/wit/workitemsbatch?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --body '{"ids": [ID1, ID2, ...], "fields": ["System.Id","System.Title","System.State","System.WorkItemType","System.IterationPath","System.Tags","System.ChangedDate"]}' \
  -o json
```

For fewer than 10 items, individual `az boards work-item show` calls are fine.

---

### Step 3: Fetch PRs and Build the Cross-Reference

**Scope PR fetching:** Only process PRs closed/created within the sprint date window (`{SPRINT_START_DATE}` to `{SPRINT_END_DATE}` + 7 days buffer). This prevents fetching hundreds of old PRs.

#### 3a: Fetch Merged PRs

```bash
az repos pr list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --creator "{USER_EMAIL}" \
  --status completed \
  --top 50 \
  -o json
```

**Hard limit:** Process linked work items for at most 20 most recent merged PRs. If more exist, warn: "Processing 20 most recent merged PRs."

For each (up to 20), fetch linked work items:

```bash
az repos pr work-item list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --id {PR_ID} \
  -o json
```

Build mapping: **work item ID → merged PRs**. Only include work item IDs that match items from Step 2 (cross-project validation — a PR may link to items in other projects).

If any call returns HTTP 429, wait 5 seconds and retry once.

#### 3b: Fetch Active (Open) PRs

```bash
az repos pr list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --creator "{USER_EMAIL}" \
  --status active \
  --top 50 \
  -o json
```

For each active PR, fetch linked work items and reviewer votes:

```bash
az repos pr work-item list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --id {PR_ID} \
  -o json
```

```bash
az repos pr reviewer list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

Classify review status:
- **Awaiting review** — no votes
- **Approved** — all required reviewers approved
- **Changes requested** — any `wait-for-author` or `reject` vote

> Note: Cross-project PRs are handled automatically — work item links resolve across projects.

---

### Step 4: Auto-Classify and Present the Plan

**Do not walk through items one-by-one.** Auto-classify everything, then present a single plan.

#### Classification Rules

| Condition | Classification | Action |
|-----------|---------------|--------|
| Has merged PR(s) linked | **RESOLVE** | Move to `{STATE_DONE}` + comment |
| Has open PR awaiting review | **PR IN REVIEW** | Comment only |
| Has open PR with changes requested | **NEEDS ATTENTION** | Flag for input |
| `{STATE_IN_PROGRESS}` + no PRs + changed < 14 days | **IN PROGRESS** | No change |
| `{STATE_IN_PROGRESS}` + no PRs + changed > 14 days | **STALE** | Flag for input |
| `{STATE_NOT_STARTED}` + no PRs | **NOT STARTED** | No change |
| Created before `{SPRINT_START_DATE}` + still `{STATE_NOT_STARTED}` | **CARRYOVER** | Flag for input |

#### Idempotency Checks

Before classifying, check for signs this command already ran:
- If an item already has a discussion comment starting with "Sprint update:", skip the comment (don't double-post).
- If an item is already in `{STATE_DONE}`, it should have been excluded by the query — but if it appears, skip it.

#### Present Classification (Compact)

> **{AUTO_COUNT}/{TOTAL_COUNT} classified:**
>
> RESOLVE ({N})
> `#{ID1}` {TITLE} — PR !{PR_ID} merged {DATE}
> `#{ID2}` {TITLE} — PR !{PR_ID} merged {DATE}
>
> PR IN REVIEW ({N})
> `#{ID3}` {TITLE} — PR !{PR_ID} ({REVIEW_STATUS})
>
> IN PROGRESS ({N})
> `#{ID4}` {TITLE}
>
> NOT STARTED ({N})
> `#{ID5}` {TITLE}
>
> NEEDS INPUT ({M})
> 1. `#{ID6}` {TITLE} — stale 21d
> 2. `#{ID7}` {TITLE} — carryover
> 3. `#{ID8}` {TITLE} — changes requested on PR !{PR_ID}
>
> Apply? [y]es [e]dit [n]o

**When the user confirms "y":**

Execute auto-classified actions. For each update:

**State transition safety:** If moving from `{STATE_NOT_STARTED}` to `{STATE_DONE}`, first transition through `{STATE_IN_PROGRESS}`:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_IN_PROGRESS}" \
  -o json
```

Then:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_DONE}" \
  --discussion "Sprint update: PR(s) merged. {SANITIZED_PR_SUMMARY}" \
  -o json
```

**Sanitizing `--discussion`:** Strip all double quotes and backticks from PR titles and user-provided text. Wrap the entire value in double quotes. Example: `--discussion "Sprint update: PR merged - Fix null ref in auth handler"`

For PR IN REVIEW items — comment only:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --discussion "Sprint update: PR !{PR_ID} under review ({REVIEW_STATUS})." \
  -o json
```

**Error handling:** If any `az boards work-item update` returns an error (409 conflict, 400 bad request, etc.), log the error inline (`#{ID} — FAILED: {error message}`) and continue with remaining items. Never abort the batch.

After each update, confirm briefly: `#{ID} → {STATE_DONE}` or `#{ID} comment added`

---

#### Step 4b: Items Needing Input

After bulk apply, present all items needing input together. Include unlinked PRs in the same prompt (so there is no separate Step 5 prompt).

> Items needing input:
> 1. `#{ID6}` {TITLE} — stale 21d, no PRs
> 2. `#{ID7}` {TITLE} — carryover
> 3. `#{ID8}` {TITLE} — changes requested on PR !{PR_ID}
> 4. PR !{PR_ID} "{PR_TITLE}" — unlinked, likely match: `#{WI_ID}`
>
> Actions: **r**esolve **n**ext-sprint **b**:"reason" **x**remove **s**kip **y**link
> Enter (e.g., `1s 2n 3b:"waiting on API team" 4y`):

**Input validation:**
- Unknown item numbers → ignore, warn: `#4 — no such item, skipped`
- Unknown action letters → treat as skip, warn: `1z — unknown action, skipped`
- Duplicate numbers → use last action
- Freeform text → attempt to interpret (e.g., "skip all" = all s). If unclear, re-prompt once.
- If an update fails mid-batch → report inline, continue.

**Parse and execute each action:**

**[r] Resolve** — with state transition safety (same as Step 4):

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_DONE}" \
  --discussion "Sprint update: Manually resolved." \
  -o json
```

**[n] Next sprint** — find next iteration by comparing start/finish dates (not alphabetical). If dates are null, sort siblings by numeric suffix (Sprint 5 before Sprint 6). If ambiguous, ask the user.

```bash
az boards iteration project list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --depth 4 \
  -o json
```

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --iteration "{NEXT_ITERATION}" \
  --discussion "Sprint update: Moved to {NEXT_ITERATION}." \
  -o json
```

**[b:"reason"] Blocked** — if reason provided inline, use it. If just `b` with no reason, use "Flagged during sprint update."

Fetch existing tags (from the batch response in Step 2, or fetch now):

```bash
az boards work-item show \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --fields "System.Tags" \
  -o json
```

**Tag safety:** Parse the existing tags string. If empty/null, set to `Blocked`. If non-empty, append `; Blocked` only if `Blocked` is not already present. Escape any semicolons in existing tag values.

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --fields "System.Tags={SAFE_TAGS}" \
  --discussion "Sprint update: BLOCKED — {SANITIZED_REASON}" \
  -o json
```

**[x] Remove** — confirm once for all items marked x before executing:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_REMOVED}" \
  --discussion "Sprint update: Removed." \
  -o json
```

If no `Removed` state exists, use `{STATE_DONE}` with comment "Removed — no longer needed."

**[y] Link** — for unlinked PR items, link to the suggested work item:

```bash
az repos pr work-item add \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --work-items {WORK_ITEM_ID} \
  -o json
```

**[s] Skip** — no action.

---

### Step 5: Handle Unlinked PRs (silent when empty)

**Skip this step entirely if all PRs are linked.** No output, no mention.

Any unlinked PRs should have already been folded into the Step 4b batch input. This step is only needed if Step 4b was skipped (no ambiguous items existed). In that case, present unlinked PRs:

> Unlinked PRs:
> 1. PR !{PR_ID} "{PR_TITLE}" — likely match: `#{WI_ID}`
> 2. PR !{PR_ID} "{PR_TITLE}" — no match
>
> Link? (e.g., `1y 2skip` or `2=12345`):

---

### Step 6: Summary and Standup

> Sprint update done. {N} resolved, {M} commented, {K} moved, {J} skipped.
>
> ---
>
> Standup (copy/paste):
>
> Yesterday: {Resolved items in plain language — e.g., "Merged OpenTelemetry trace fix (PR !1474128) and App Insights integration (PR !1468981)."}
> Today: {In-progress items + PRs awaiting review, deduplicated — e.g., "Continuing TMP Migration. PR !1462531 under review."}
> Blocked: {Blocked items or "None"}

Use plain text only — no bold, no markdown formatting. This must paste cleanly into Slack, Teams, or any standup bot. Keep each section to 1-2 sentences.

**No rollback.** If the user needs to undo changes, they must use Azure DevOps history on individual work items. Mention this if an error occurs mid-batch.

---

## Communication Style

- **Auto-classify first, ask questions second.** Developer confirms a plan, not builds one.
- **Bulk confirmation is the default.** Only surface items individually when they need human judgment.
- **Batch input for ambiguous items.** One response like `1s 2n 3b:"reason"` handles everything.
- **Single-line confirmations.** `#{ID} → Resolved` — no filler.
- **Skip means skip.** No follow-up.
- **The standup is the deliverable.** Plain text, no formatting, copy-paste ready.
- **Target: under 2 minutes, max 3 developer inputs** for a typical 10-20 item sprint.
- **Never auto-link PRs without confirmation.** Always present for user review.
- **Errors don't abort.** Log inline, continue the batch, report at the end.

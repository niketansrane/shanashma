---
name: adoflow:sprint-update
description: Auto-classify sprint work items using merged/open PRs, bulk-confirm updates, flag blockers, move items to next sprint, and generate a copy-paste standup summary
argument-hint: "[update my sprint items | quick sprint update | sprint standup | move #1234 to next sprint]"
---

# Azure DevOps Sprint Update

Keep your sprint board accurate in under a minute. Auto-classifies work items by PR activity, bulk-confirms the obvious ones, walks through only ambiguous items, and generates a standup summary.

> **Design note:** Sprint-update proceeds with the full workflow by default without prompting. This is intentional — the daily standup use case means the intent is always "update everything."

## Arguments

<user_request> #$ARGUMENTS </user_request>

**If the request above is empty, proceed with the default workflow:** auto-classify and update all active sprint work items.

## Prerequisites

Load the shared configuration by following the setup instructions in the `ado-flow` skill's "First-Time Setup" section.

```bash
cat ~/.config/ado-flow/config.json 2>/dev/null
```

If no config exists, follow the `ado-flow` skill to run first-time setup. Once config is loaded, you will have: `{ORG}`, `{WORK_ITEM_PROJECT}`, `{PR_PROJECT}`.

Resolve the user's identity for queries:

```bash
az account show --query "user.name" -o tsv
```

Store this as `{USER_EMAIL}`. **Validate it looks like an email address** (contains `@`). If it returns a GUID or display name instead, ask the user for their email.

---

## Workflow

### Step 1: Detect the Current Sprint Iteration Path

Fetch the user's recent work items to determine the current sprint iteration path, following the "Detecting Area Path and Iteration Path from Recent Work Items" section in the shared skill.

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me ORDER BY [System.ChangedDate] DESC" \
  -o json
```

From the results, identify the current sprint iteration path (the most recent non-backlog, non-root iteration path). Use this as `{CURRENT_ITERATION}`.

**If the query returns zero results**, fall back to using `{USER_EMAIL}` in the WIQL `WHERE` clause instead of `@me`:

```bash
--wiql "SELECT [System.Id], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = '{USER_EMAIL}' ORDER BY [System.ChangedDate] DESC"
```

If still no results, ask the user:

> "I couldn't detect your current sprint. What's the iteration path? (e.g., `MyProject\\Sprint 5`)"

---

### Step 2: Detect Process Template States

Detect the valid states for work items in this project:

```bash
az boards work-item type state list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --type "Task" \
  -o json
```

From the results, build a state mapping for this session:

| Intent | Agile | Scrum | CMMI | Basic |
|--------|-------|-------|------|-------|
| Not started | New | New | Proposed | To Do |
| In progress | Active | Committed | Active | Doing |
| Done | Resolved | Done | Resolved | Done |
| Closed | Closed | Done | Closed | Done |
| Removed | Removed | Removed | Closed | Done |

Store the detected state names:
- `{STATE_NOT_STARTED}` — the "new/proposed/to do" state
- `{STATE_IN_PROGRESS}` — the "active/committed/doing" state
- `{STATE_DONE}` — the terminal "resolved/done" state
- `{STATE_REMOVED}` — the "removed/closed" state (if it exists; some templates don't have it)

**Always use these detected variables instead of hardcoded state names.**

Also build a dynamic exclusion list for the WIQL in Step 3: collect all terminal/done/closed/removed state names from the state list response. Use these in the `NOT IN` clause instead of hardcoding.

---

### Step 3: Fetch Active Work Items in the Current Sprint

Query all work items assigned to the user in the current sprint that are not yet done. Use the dynamically detected terminal states from Step 2 in the `NOT IN` clause:

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType], [System.IterationPath], [System.Tags], [System.CreatedDate], [System.ChangedDate] FROM workitems WHERE [System.AssignedTo] = @me AND [System.IterationPath] = '{CURRENT_ITERATION}' AND [System.State] NOT IN ({DYNAMIC_TERMINAL_STATES}) ORDER BY [System.WorkItemType] ASC, [System.State] ASC" \
  -o json
```

**If zero results with `@me`**, retry with `{USER_EMAIL}` in the `WHERE` clause.

**If still zero results**, inform the user: "No active items found in `{CURRENT_ITERATION}`. Your sprint board looks clean!" and skip to Step 7 (standup summary with empty content).

---

### Step 4: Fetch PRs and Build the Cross-Reference

#### 4a: Fetch Merged PRs

```bash
az repos pr list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --creator "{USER_EMAIL}" \
  --status completed \
  --top 100 \
  -o json
```

If exactly 100 results, warn: "Fetched max 100 PRs. Some older ones may be missing."

For each merged PR, fetch linked work items:

```bash
az repos pr work-item list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

**Rate limiting:** If you have many PRs, batch these calls in groups of 10-15 with brief pauses. If any call returns HTTP 429, wait 5 seconds and retry once.

Build a mapping: **work item ID → list of merged PRs** (with PR title, repo, date).

**Cross-project validation:** When matching PR-linked work item IDs to sprint items, verify the work item ID actually exists in your sprint item list. PRs may link to work items in other projects with coincidentally similar IDs.

#### 4b: Fetch Active (Open) PRs

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
  --id {PR_ID} \
  -o json
```

```bash
az repos pr reviewer list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

Build a second mapping: **work item ID → list of open PRs** (with PR title, repo, draft status, reviewer votes).

Classify each open PR's review status:
- **Awaiting review** — no votes yet
- **Approved** — all required reviewers approved
- **Changes requested** — at least one `wait-for-author` or `reject` vote

#### 4c: Handle Cross-Project PRs

If `{WORK_ITEM_PROJECT}` and `{PR_PROJECT}` are different, the above queries already handle it — work items are from one project, PRs from another, and the link is resolved via PR-linked work items.

---

### Step 5: Auto-Classify and Present the Plan

**Do not walk through items one-by-one.** Auto-classify everything, then present a single plan for bulk confirmation.

#### Classification Rules

For each active work item, classify automatically:

| Condition | Classification | Action |
|-----------|---------------|--------|
| Has merged PR(s) linked | **RESOLVE** | Move to `{STATE_DONE}` + comment |
| Has open PR awaiting review | **PR IN REVIEW** | Comment (no state change) |
| Has open PR with changes requested | **NEEDS ATTENTION** | Flag for manual review |
| `{STATE_IN_PROGRESS}` + no PRs + changed < 14 days ago | **IN PROGRESS** | No change |
| `{STATE_IN_PROGRESS}` + no PRs + changed > 14 days ago | **STALE** | Flag for input |
| `{STATE_NOT_STARTED}` + no PRs | **NOT STARTED** | No change |
| Created before sprint start + still `{STATE_NOT_STARTED}` | **CARRYOVER** | Suggest move |

#### Present the Auto-Classification (Compact Format)

Use this dense format — one line per item, grouped by classification:

> **{AUTO_COUNT}/{TOTAL_COUNT} classified:**
>
> **RESOLVE** ({N})
> `#{ID1}` {TITLE} — PR !{PR_ID} merged {DATE}
> `#{ID2}` {TITLE} — PR !{PR_ID} merged {DATE}
>
> **PR IN REVIEW** ({N})
> `#{ID3}` {TITLE} — PR !{PR_ID} ({REVIEW_STATUS})
>
> **IN PROGRESS** ({N})
> `#{ID4}` {TITLE}
>
> **NOT STARTED** ({N})
> `#{ID5}` {TITLE}
>
> **NEEDS INPUT** ({M}) — see below
> `#{ID6}` {TITLE} — stale 21d
> `#{ID7}` {TITLE} — carryover
>
> Apply? [y] yes / [e] edit / [n] cancel

**When the user confirms "y" or "yes":**

Execute all auto-classified actions. For RESOLVE items, handle state transitions carefully:

**State transition safety:** If the item is in `{STATE_NOT_STARTED}` and needs to move to `{STATE_DONE}`, first transition through `{STATE_IN_PROGRESS}` (some process templates don't allow skipping states):

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_IN_PROGRESS}" \
  -o json
```

Then move to done:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_DONE}" \
  --discussion "Sprint update: PR(s) merged. {PR_SUMMARY}" \
  -o json
```

**Sanitize the `--discussion` value:** Replace any double quotes, backticks, or shell metacharacters in PR titles before embedding them in the `--discussion` argument. Use single quotes around the value if needed.

For PR IN REVIEW items — add a comment only (no state change):

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --discussion "Sprint update: PR !{PR_ID} under review ({REVIEW_STATUS})." \
  -o json
```

For IN PROGRESS and NOT STARTED items — no action taken.

**After each update, confirm briefly:** `#{ID} → {STATE_DONE}` or `#{ID} comment added`

---

#### Step 5b: Walk Through Items Needing Input

After bulk-applying, handle STALE, NEEDS ATTENTION, CARRYOVER items, and any the user asked to edit.

**Batch input format:** Present all items needing input at once and accept a single response using the format `{number}{action}` separated by spaces:

> **Items needing input:**
> 1. `#{ID6}` {TITLE} — stale 21d, no PRs
> 2. `#{ID7}` {TITLE} — carryover from last sprint
> 3. `#{ID8}` {TITLE} — PR has changes requested
>
> Actions: **r**esolve **n**ext-sprint **b**locked **x**remove **s**kip
> Enter actions (e.g., `1s 2n 3b`):

This lets the developer handle all ambiguous items in one response instead of answering per-item.

**Parse the response** and execute each action:

**[r] Resolve** — move to `{STATE_DONE}` (with state transition safety as above):

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_DONE}" \
  --discussion "Sprint update: Manually resolved." \
  -o json
```

**[n] Next sprint** — detect next iteration by date order, move the item without additional confirmation (this is reversible):

```bash
az boards iteration project list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --depth 4 \
  -o json
```

**Find the next iteration by comparing start/finish dates**, not alphabetical order. The next iteration is the one whose start date is after `{CURRENT_ITERATION}`'s end date, sorted chronologically. If dates aren't available, use the iteration path structure (next sibling at same level).

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --iteration "{NEXT_ITERATION}" \
  --discussion "Sprint update: Moved to {NEXT_ITERATION}." \
  -o json
```

**[b] Blocked** — ask "What's blocking these?" (one prompt for all blocked items), then for each:

Fetch existing tags first to avoid overwriting:

```bash
az boards work-item show \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --fields "System.Tags" \
  -o json
```

Extract tags from the JSON response and append `Blocked`:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --fields "System.Tags={EXISTING_TAGS}; Blocked" \
  --discussion "Sprint update: BLOCKED — {BLOCKER_DESCRIPTION}" \
  -o json
```

**[x] Remove** — confirm once for all items marked for removal, then:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_REMOVED}" \
  --discussion "Sprint update: Removed." \
  -o json
```

If the process template has no `Removed` state (detected in Step 2), use `{STATE_DONE}` instead with a comment noting it was removed.

**[s] Skip** — no action, move on.

---

### Step 6: Handle Unlinked PRs

Check if any merged or open PRs were not linked to any active sprint work item.

For unlinked PRs with high-confidence title matches (>80% similarity), auto-link without asking:

```bash
az repos pr work-item add \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --work-items {WORK_ITEM_ID} \
  -o json
```

For low-confidence matches, present as a single batch:

> **Unlinked PRs:**
> 1. PR !{PR_ID} "{PR_TITLE}" — likely match: `#{WI_ID}` "{WI_TITLE}"
> 2. PR !{PR_ID} "{PR_TITLE}" — no match found
>
> Link? (e.g., `1y 2skip` or `2=12345`):

---

### Step 7: Final Summary and Standup

Present the action log and standup summary together.

> **Sprint update done.** {N} resolved, {M} commented, {K} moved, {J} skipped.
>
> ---
>
> **Standup** (copy/paste):
>
> **Yesterday:** {Resolved items summarized in plain language — e.g., "Merged OpenTelemetry trace fix (PR !1474128) and App Insights integration (PR !1468981)."}
>
> **Today:** {In-progress + PR-in-review items — e.g., "Continuing TMP Migration. PR !1462531 (SLA boundary fix) under review."}
>
> **Blocked:** {Blocked items or "Nothing flagged."}
>
> **PRs needing review:** {Open PRs with status — e.g., "PR !1462531 (draft, Skynet), PR !1462304 (awaiting review, Skynet)."}

---

## Communication Style

- **Auto-classify first, ask questions second.** Developer confirms a plan, not builds one.
- **Bulk confirmation is the default.** Only surface items individually when they need human judgment.
- **Batch input for ambiguous items.** One response like `1s 2n 3b` handles everything.
- **Single-line confirmations.** `#{ID} → Resolved` — no filler.
- **Skip means skip.** No follow-up.
- **The standup summary is the deliverable.** ADO updates are the means; standup text is what makes developers come back daily.
- **Target: under 2 minutes** for a typical 10-20 item sprint. 3 developer inputs max.

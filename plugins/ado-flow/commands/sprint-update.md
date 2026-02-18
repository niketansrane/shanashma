---
name: adoflow:sprint-update
description: Auto-classify sprint work items using merged/open PRs, bulk-confirm updates, flag blockers, move items to next sprint, and generate a copy-paste standup summary
argument-hint: "[update my sprint items | quick sprint update | sprint standup | move #1234 to next sprint]"
---

# Azure DevOps Sprint Update

Keep your sprint board accurate in under a minute. This command auto-classifies your work items based on PR activity, lets you bulk-confirm the obvious ones, walks you through only the ambiguous items, and generates a copy-paste standup summary at the end.

> **Design note:** Unlike other adoflow commands, sprint-update proceeds with the full workflow by default without prompting. This is intentional — the command is designed for the daily standup use case where the intent is always "update everything."

## Arguments

<user_request> #$ARGUMENTS </user_request>

**If the request above is empty, proceed with the default workflow:** auto-classify and update all active sprint work items.

## Prerequisites

Before doing anything, load the shared configuration by following the setup instructions in the `ado-flow` skill's "First-Time Setup" section.

```bash
cat ~/.config/ado-flow/config.json 2>/dev/null
```

If no config exists, follow the `ado-flow` skill to run first-time setup. Once config is loaded, you will have: `{ORG}`, `{WORK_ITEM_PROJECT}`, `{PR_PROJECT}`.

Also resolve the user's email for PR queries (since `@me` may not resolve in cross-project contexts):

```bash
az account show --query "user.name" -o tsv
```

Store this as `{USER_EMAIL}`.

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

If no clear iteration is found, ask the user:

> "I couldn't detect your current sprint. Could you tell me the iteration path? (e.g., `MyProject\\Sprint 5`)"

---

### Step 2: Detect Process Template States

Before suggesting any state transitions, detect the valid states for work items in this project. Fetch the state model:

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

Store the detected state names as variables used throughout Step 5:
- `{STATE_NOT_STARTED}` — the "new/proposed/to do" state
- `{STATE_IN_PROGRESS}` — the "active/committed/doing" state
- `{STATE_DONE}` — the terminal "resolved/done" state
- `{STATE_REMOVED}` — the "removed/closed" state for unwanted items

**Always use these detected variables instead of hardcoded state names.**

---

### Step 3: Fetch Active Work Items in the Current Sprint

Query all work items assigned to the user in the current sprint that are not yet done:

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType], [System.IterationPath], [System.Tags], [System.CreatedDate], [System.ChangedDate] FROM workitems WHERE [System.AssignedTo] = @me AND [System.IterationPath] = '{CURRENT_ITERATION}' AND [System.State] NOT IN ('Closed', 'Removed', 'Resolved', 'Done') ORDER BY [System.WorkItemType] ASC, [System.State] ASC" \
  -o json
```

**Note:** The `NOT IN` clause excludes items that are already resolved/done/closed/removed, so the command only processes items that still need attention.

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

If exactly 100 results are returned, warn: "I fetched the maximum number of recent PRs. Some older ones may be missing."

For each merged PR, fetch its linked work items:

```bash
az repos pr work-item list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

Build a mapping: **work item ID → list of merged PRs** (with PR title, repo, date).

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

For each active PR, fetch its linked work items and reviewer votes:

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

If the user mentions PRs in a third project, query that project additionally and merge results.

---

### Step 5: Auto-Classify and Present the Plan

This is the core of the command. **Do not walk through items one-by-one by default.** Instead, auto-classify every item using the data collected, then present a single plan for bulk confirmation.

#### Classification Rules

For each active work item, classify it automatically:

| Condition | Classification | Suggested Action |
|-----------|---------------|------------------|
| Has merged PR(s) linked | **RESOLVE** | Move to `{STATE_DONE}` + add PR summary comment |
| Has open PR awaiting review | **PR IN REVIEW** | Add "PR under review" comment |
| Has open PR with changes requested | **NEEDS ATTENTION** | Flag for manual review |
| State is `{STATE_IN_PROGRESS}` + no PRs + changed < 14 days ago | **IN PROGRESS** | No change needed |
| State is `{STATE_IN_PROGRESS}` + no PRs + changed > 14 days ago | **STALE** | Flag for discussion |
| State is `{STATE_NOT_STARTED}` + no PRs | **NOT STARTED** | No change needed |
| Title contains `[Placeholder]` | **PLACEHOLDER** | Suggest removal or clarification |
| Item created before current sprint started + still `{STATE_NOT_STARTED}` | **CARRYOVER** | Suggest move to next sprint or backlog |

**Also detect duplicates:** If two or more items share the same title or the same linked PR, flag them as a group.

#### Present the Auto-Classification

> Auto-classified **{AUTO_COUNT}** of **{TOTAL_COUNT}** items:
>
> **RESOLVE** ({N}) — merged PR found
> &nbsp;&nbsp;#{ID1} {TITLE} — PR #{PR_ID} merged {DATE}
> &nbsp;&nbsp;#{ID2} {TITLE} — PR #{PR_ID} merged {DATE}
>
> **PR IN REVIEW** ({N}) — open PR, awaiting merge
> &nbsp;&nbsp;#{ID3} {TITLE} — PR #{PR_ID} ({REVIEW_STATUS})
>
> **IN PROGRESS** ({N}) — Active, no PRs
> &nbsp;&nbsp;#{ID4} {TITLE}
>
> **NOT STARTED** ({N}) — Proposed, no activity
> &nbsp;&nbsp;#{ID5} {TITLE}
>
> Apply auto-classifications? (yes / no / edit by number)

**When the user confirms "yes" or "apply all":**

Execute all auto-classified actions in sequence:

For RESOLVE items — update state + add comment:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_DONE}" \
  --discussion "Sprint update: {N} PR(s) merged.<br>- PR #{PR_ID}: {PR_TITLE} (merged {DATE} into {TARGET_BRANCH} in {REPO})" \
  -o json
```

For PR IN REVIEW items — add a comment:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --discussion "Sprint update: PR #{PR_ID} is open and under review ({REVIEW_STATUS})." \
  -o json
```

For IN PROGRESS and NOT STARTED items — no action taken (they are already in the correct state).

**When the user says "edit" or selects specific numbers:**

Present each selected item individually for override (see Step 5b).

---

#### Step 5b: Walk Through Items Needing Input

After bulk-applying the auto-classifications, walk through only the items that need human input: STALE, NEEDS ATTENTION, PLACEHOLDER, CARRYOVER, and any the user asked to edit.

For each item, use a consistent single-letter action menu:

> **#{ID} - {TITLE}** ({STATE}, {TYPE})
> {CONTEXT: e.g., "No PRs, no activity for 21 days" or "Open PR has changes requested by Jane Smith"}
>
> **[r]**esolve &nbsp; **[p]**rogress comment &nbsp; **[n]**ext sprint &nbsp; **[b]**locked &nbsp; **[x]** remove &nbsp; **[s]**kip

**Actions:**

**[r] Resolve** — move to `{STATE_DONE}` + add comment:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_DONE}" \
  --discussion "Sprint update: Work complete." \
  -o json
```

**[p] Progress comment** — ask "Quick note on where things stand?" then:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --discussion "Sprint update: In progress — {USER_NOTE}" \
  -o json
```

If item is in `{STATE_NOT_STARTED}`, also move to `{STATE_IN_PROGRESS}`:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_IN_PROGRESS}" \
  -o json
```

**[n] Next sprint** — detect the next iteration and move the item there:

```bash
az boards iteration project list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --depth 4 \
  -o json
```

Find the iteration path that comes after `{CURRENT_ITERATION}` chronologically. Confirm:

> "Moving #{ID} to `{NEXT_ITERATION}`. Correct?"

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --iteration "{NEXT_ITERATION}" \
  --discussion "Sprint update: Moved to {NEXT_ITERATION} — not completed this sprint." \
  -o json
```

**[b] Blocked** — ask "What's blocking this?" then add comment and append tag:

First fetch existing tags to avoid overwriting:

```bash
az boards work-item show \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --fields "System.Tags" \
  --query "fields.\"System.Tags\"" \
  -o tsv
```

Then append `Blocked` to existing tags:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --fields "System.Tags={EXISTING_TAGS}; Blocked" \
  --discussion "Sprint update: BLOCKED — {BLOCKER_DESCRIPTION}" \
  -o json
```

**[x] Remove** — confirm first, then:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_REMOVED}" \
  --discussion "Sprint update: Removed — no longer needed." \
  -o json
```

**[s] Skip** — move on immediately, no follow-up.

---

### Step 6: Handle Unlinked PRs

After all work item updates, check if any merged or open PRs were not linked to any active sprint work item.

For unlinked PRs, attempt a title-similarity match against sprint work items and show confidence:

> **Unlinked PRs** ({W}):
> 1. PR #{PR_ID}: "{PR_TITLE}" in `{REPO}` — merged {DATE}
>    Likely match: #{WI_ID} "{WI_TITLE}" (high confidence based on title similarity)
>    Link to #{WI_ID}? (y / n / other ID)
>
> 2. PR #{PR_ID}: "{PR_TITLE}" in `{REPO}` — merged {DATE}
>    No strong match found.
>    Link to a work item? (enter ID or skip)

To link:

```bash
az repos pr work-item add \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --work-items {WORK_ITEM_ID} \
  -o json
```

---

### Step 7: Final Summary and Standup

After all updates, present two things: the action log and the standup summary.

#### Action Log

> ## Sprint Update Complete
>
> **Actions taken:**
> - Resolved: #{ID1}, #{ID2} (with PR summary comments)
> - PR in review: #{ID3} (comment added)
> - Progress comment: #{ID4}
> - Blocked: #{ID5} (tagged + comment)
> - Moved to next sprint: #{ID6} → {NEXT_ITERATION}
> - Removed: #{ID7}
> - Linked: PR #{PR_ID} → #{WI_ID}
> - Skipped: #{ID8}, #{ID9}

#### Standup Summary

Generate a copy-paste standup message based on everything learned during the update:

> ## Your Standup (copy/paste ready)
>
> **Yesterday:**
> {List items that were resolved — summarize merged PRs in plain language}
> e.g., "Merged OpenTelemetry trace propagation fix (PR #1474128) and App Insights integration (PR #1468981)."
>
> **Today:**
> {List items that are in progress or have open PRs}
> e.g., "Continuing TMP Migration to Ownership Enforcer. PR #1462531 (SLA boundary fix) is under review."
>
> **Blocked:**
> {List items flagged as blocked, with the blocker description}
> e.g., "Nothing flagged." or "#5134465 blocked on infrastructure team response."
>
> **PRs awaiting review:**
> {List open PRs with their review status}
> e.g., "PR #1462531 (draft, Skynet), PR #1462304 (draft, Skynet)."

---

## Communication Style

In addition to the communication guidelines in the `ado-flow` shared skill, sprint-update follows these specific interaction patterns:

- **Auto-classify first, ask questions second.** The developer should confirm a plan, not construct one from scratch.
- **Bulk confirmation is the default.** Only surface items individually when they genuinely need human judgment.
- Use consistent single-letter shortcuts: **[r]** resolve, **[p]** progress, **[n]** next sprint, **[b]** blocked, **[x]** remove, **[s]** skip.
- After each update, confirm briefly: "Done — #{ID} moved to Resolved."
- If the developer says "skip" or "s", move on immediately — no follow-up.
- **The standup summary is the deliverable.** The ADO updates are the means; the standup text is what makes developers come back daily.
- Keep the entire flow under 2 minutes for a typical sprint of 10-20 items.

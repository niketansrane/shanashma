---
name: adoflow:sprint-update
description: Auto-classify sprint work items using merged/open PRs, bulk-confirm updates, and flag blockers
argument-hint: "[update my sprint items | quick sprint update]"
---

# Azure DevOps Sprint Update

Keep your sprint board accurate in under a minute. Auto-classifies work items by PR activity, bulk-confirms the obvious ones, and walks through only ambiguous items.

## Arguments

<user_request> $ARGUMENTS </user_request>

**If the request above is empty, proceed with the default workflow:** auto-classify and update all active sprint work items.

---

## Global Rules

**Follow these rules throughout the entire workflow. Violations cause cascading failures.**

### Output Handling (Windows Compatibility)

1. **Always redirect `az` output to a file.** Never parse `az` output inline or pipe it. The Windows `az` CLI emits encoding warnings (`WARNING: Unable to encode the output with cp1252 encoding`) that corrupt JSON output. The safe pattern is:

```bash
az <command> -o json 2>/dev/null > "$HOME/ado-flow-tmp-{PURPOSE}.json"
```

2. **Always use `$HOME` for temp files.** Do not use `/tmp/`, `$TMPDIR`, or `$TEMP` — these resolve differently between bash and Node.js on Windows (`/tmp/` → `C:\tmp\` in Node.js, which does not exist). Always use `$HOME` which is consistent across both.

3. **Use `node -e` for all JSON processing.** Never use `python3`. Never pipe into `node -e` via stdin (`/dev/stdin` does not exist on Windows). Always read from a file:

```bash
# CORRECT: write to file, then parse with node
az boards query ... -o json 2>/dev/null > "$HOME/ado-flow-tmp-query.json"
node -e "
const data = JSON.parse(require('fs').readFileSync(require('path').join(require('os').homedir(), 'ado-flow-tmp-query.json'), 'utf8'));
console.log(JSON.stringify(data, null, 2));
"
```

```bash
# WRONG: piping (breaks on Windows)
az boards query ... | node -e "..."
# WRONG: /dev/stdin (does not exist on Windows)
node -e "require('fs').readFileSync('/dev/stdin')"
# WRONG: /tmp/ path (resolves to C:\tmp\ in Node.js)
az ... > /tmp/foo.json
```

4. **Clean up temp files** at the end of the run:
```bash
rm -f "$HOME"/ado-flow-tmp-*.json 2>/dev/null
```

### Execution Rules

5. **Never run data-collection commands in the background.** All data must be fully collected and parsed before presenting the classification plan. Background tasks that complete after the plan is shown are useless.

6. **Never loop through PRs individually to fetch linked work items.** The `$expand=Relations` batch API (Phase 2b) provides all PR links in a single call. If you find yourself writing `for PR_ID in ... do az repos pr work-item list`, you are doing it wrong.

7. **Respect the `--top` limits exactly:** `--top 30` for merged PRs, `--top 20` for active PRs. Do not increase these.

8. **Cache everything immediately.** After resolving `user_email`, sprint context, or work item states — write to config in the same step. Do not defer caching.

---

## Diagnostics

Track these metrics throughout every run:

- `{CALL_COUNT}` — increment by 1 for every `az` or `az rest` command executed (do NOT count `node`, `cat`, or `rm`)
- `{START_TIME}` — note the wall-clock time when you begin the first az command

### Expected Call Counts (for comparison)

| Scenario | Old flow | Optimized flow |
|----------|----------|----------------|
| 10 items, 5 merged PRs, 3 active PRs | ~22-28 calls | ~8-12 calls |
| 5 items, 2 merged PRs, 1 active PR | ~12-16 calls | ~6-8 calls |
| 15 items, 10 merged PRs, 5 active PRs | ~35-45 calls | ~10-15 calls |
| Repeat run (cached sprint context) | same as above | -2 calls (cache hit) |

**You MUST output the diagnostic line at the end of every run (Phase 6), before asking for any user input.** If your actual call count exceeds the "Optimized flow" estimate by more than 3, review whether unnecessary calls were made.

---

## Phase 0: Setup (0-1 az calls)

Load the shared configuration:

```bash
cat "$HOME/.config/ado-flow/config.json" 2>/dev/null
```

If no config exists, follow the `ado-flow` skill to run first-time setup.

**Config key normalization:** The config may use either lowercase (`organization`, `work_item_project`, `pr_project`) or uppercase (`ORG`, `WORK_ITEM_PROJECT`, `PR_PROJECT`) keys. Accept either format. Map to variables:
- `{ORG}` = `organization` or `ORG`
- `{WORK_ITEM_PROJECT}` = `work_item_project` or `WORK_ITEM_PROJECT`
- `{PR_PROJECT}` = `pr_project` or `PR_PROJECT`

### Project Routing Rule

**These two projects may be different.** Always use the correct one:

| API | Project variable |
|-----|-----------------|
| `az boards query`, `az boards work-item *`, `az boards iteration *` | `{WORK_ITEM_PROJECT}` |
| `az rest` with `_apis/wit/*` (batch, states) | `{WORK_ITEM_PROJECT}` |
| `az repos pr list`, `az repos pr create` | `{PR_PROJECT}` |
| `az repos pr reviewer list`, `az repos pr work-item add` | No `--project` needed (uses `--id`) |

**Never swap these.** Using `{PR_PROJECT}` for work item queries or `{WORK_ITEM_PROJECT}` for PR listing will return empty results or errors when the projects differ.

### Resolve User Identity

Check the config for a `user_email` key. **If present, use it directly — no az call needed.**

If `user_email` is missing from the config:

```bash
az account show --query "user.name" -o tsv 2>/dev/null
```

**Validate it contains `@`.** If it returns a GUID or display name, ask the user for their email. **You MUST cache it immediately:**

```bash
node -e "
const fs = require('fs'), path = require('path'), os = require('os');
const dir = path.join(os.homedir(), '.config', 'ado-flow');
const p = path.join(dir, 'config.json');
fs.mkdirSync(dir, { recursive: true });
const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
cfg.user_email = '{USER_EMAIL}';
fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
"
```

---

## Phase 1: Resolve Sprint Context (0 az calls if cached, 2 if not)

### 1a: Sprint Iteration + Dates (cached after first run)

Check the config for a `sprint_cache` key:

```json
{
  "sprint_cache": {
    "iteration_path": "Project\\Sprint 5",
    "start_date": "2024-01-15",
    "end_date": "2024-01-29"
  }
}
```

**Cache is valid if** today's date ≤ `end_date`. If valid, load `{CURRENT_ITERATION}`, `{SPRINT_START_DATE}`, `{SPRINT_END_DATE}` directly from cache. **Skip to Phase 2.**

**If stale or missing**, detect the sprint:

**Step 1 — Detect iteration path** from the user's recent non-done work items (1 az call):

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me AND [System.State] NOT IN ({DYNAMIC_TERMINAL_STATES}) ORDER BY [System.ChangedDate] DESC" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-iterations.json"
```

Parse the results with node. Identify the most recent non-backlog, non-root iteration path (exclude single-segment paths and paths containing "Backlog"). Store as `{CURRENT_ITERATION}`.

**If zero results with `@me`**, retry with `{USER_EMAIL}` in the `WHERE` clause. If still nothing, ask the user for their iteration path.

**Step 2 — Fetch sprint dates** using the REST API (1 az call). **Do NOT use `az boards iteration project show`** — it requires `--id` (a GUID), not a path, and will fail.

Instead, list all iterations and filter by path:

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{WORK_ITEM_PROJECT}/_apis/work/teamsettings/iterations?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-team-iterations.json"
```

Then parse with node to find the matching iteration:

```bash
node -e "
const fs = require('fs'), path = require('path'), os = require('os');
const data = JSON.parse(fs.readFileSync(path.join(os.homedir(), 'ado-flow-tmp-team-iterations.json'), 'utf8'));
const target = '{CURRENT_ITERATION}';
const match = data.value.find(i => i.path && i.path.replace(/^\\\\/,'').replace(/\\\\/g,'\\\\') === target);
if (match && match.attributes) {
  console.log(JSON.stringify({
    start: match.attributes.startDate,
    end: match.attributes.finishDate
  }));
} else {
  console.log('NO_MATCH');
}
"
```

If `NO_MATCH` is returned, the iteration may not be part of the default team's settings. Fall back to asking the user for the sprint dates, or try the project-level iterations API:

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{WORK_ITEM_PROJECT}/_apis/wit/classificationnodes/Iterations?api-version=7.1&\$depth=5" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-project-iterations.json"
```

Parse recursively to find the matching node by path. Iteration nodes have `attributes.startDate` and `attributes.finishDate`.

Store `{SPRINT_START_DATE}` and `{SPRINT_END_DATE}`.

**Cache the sprint context immediately:**

```bash
node -e "
const fs = require('fs'), path = require('path'), os = require('os');
const dir = path.join(os.homedir(), '.config', 'ado-flow');
const p = path.join(dir, 'config.json');
fs.mkdirSync(dir, { recursive: true });
const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
cfg.sprint_cache = {
    iteration_path: '{CURRENT_ITERATION}',
    start_date: '{SPRINT_START_DATE}',
    end_date: '{SPRINT_END_DATE}'
};
fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
"
```

### 1b: Load Work Item States (one-time detection, cached in config)

Check the config for a `work_item_states` key. **If present, use it directly — no az calls needed.**

The cached format is:

```json
{
  "work_item_states": {
    "Task": { "not_started": "New", "in_progress": "Active", "done": "Closed", "removed": "Removed" },
    "Bug": { "not_started": "New", "in_progress": "Active", "done": "Resolved", "removed": "Removed" }
  }
}
```

**If `work_item_states` is missing**, detect states and save them to the config:

1. Fetch Task states first (1 az call). Most ADO templates use the same states across types — check Task, then only fetch Bug if it differs.

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{WORK_ITEM_PROJECT}/_apis/wit/workitemtypes/Task/states?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-task-states.json"
```

2. From the response, classify states using the `stateCategory` field (not the display name):
   - `not_started` — category = `Proposed`
   - `in_progress` — category = `InProgress`
   - `done` — category = `Resolved` or `Completed`
   - `removed` — category = `Removed` (may not exist in all templates)

3. Also fetch Bug states (1 az call). Only fetch additional types (User Story, PBI) if work items of those types appear in the sprint.

4. **Cache immediately** — merge into existing config JSON and save using the node pattern above.

Once loaded, map the states to variables:
- `{STATE_NOT_STARTED}` — `work_item_states[type].not_started`
- `{STATE_IN_PROGRESS}` — `work_item_states[type].in_progress`
- `{STATE_DONE}` — `work_item_states[type].done`
- `{STATE_REMOVED}` — `work_item_states[type].removed`

Build `{DYNAMIC_TERMINAL_STATES}` — a single-quoted, comma-separated WIQL list of all unique `done` and `removed` values across types: e.g., `'Closed', 'Resolved', 'Removed'`.

---

## Phase 2: Fetch Sprint Work Items with PR Links (2 az calls)

This is the core optimization: **one query + one batch fetch replaces the old approach of separate iteration detection, work item fetch, and per-PR work-item-list loops.**

### 2a: Query Active Sprint Items

**WIQL escaping:** If `{CURRENT_ITERATION}` contains single quotes, escape them by doubling: `'` → `''`.

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id] FROM workitems WHERE [System.AssignedTo] = @me AND [System.IterationPath] = '{CURRENT_ITERATION}' AND [System.State] NOT IN ({DYNAMIC_TERMINAL_STATES}) ORDER BY [System.WorkItemType] ASC" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-sprint-items.json"
```

**If zero results with `@me`**, retry with `{USER_EMAIL}`. If still zero, output "No active items in `{CURRENT_ITERATION}`. Sprint board looks clean!" and stop.

Extract the list of work item IDs from the response.

### 2b: Batch Fetch with Relations

**Always use the batch API** regardless of item count. The batch API returns full field values AND relations (including PR artifact links) in a single call.

First, write the request body to a file (avoids JSON escaping issues in shell):

```bash
node -e "
const fs = require('fs'), path = require('path'), os = require('os');
const body = {
  ids: [{COMMA_SEPARATED_IDS}],
  '\$expand': 'Relations',
  fields: [
    'System.Id', 'System.Title', 'System.State',
    'System.WorkItemType', 'System.IterationPath',
    'System.Tags', 'System.ChangedDate'
  ]
};
fs.writeFileSync(path.join(os.homedir(), 'ado-flow-tmp-batch-body.json'), JSON.stringify(body));
"
```

Then make the batch call:

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WORK_ITEM_PROJECT}/_apis/wit/workitemsbatch?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --body "@$HOME/ado-flow-tmp-batch-body.json" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-batch-result.json"
```

### 2c: Extract PR Links from Relations

The batch response is a JSON object with a `value` array. Each work item has a `relations` array (may be `null` if no relations exist). PR links look like this in the actual response:

```json
{
  "count": 2,
  "value": [
    {
      "id": 12345,
      "fields": {
        "System.Id": 12345,
        "System.Title": "Fix login bug",
        "System.State": "Active",
        "System.WorkItemType": "Task",
        "System.Tags": "",
        "System.ChangedDate": "2024-01-20T10:00:00Z"
      },
      "relations": [
        {
          "rel": "ArtifactLink",
          "url": "vstfs:///Git/PullRequestId/a7573007-bbb3-4341-b726-0c4148a07853/3411ebc1-d5aa-464f-9615-0b527bc66719/1478118",
          "attributes": {
            "name": "Pull Request"
          }
        },
        {
          "rel": "System.LinkTypes.Hierarchy-Reverse",
          "url": "https://dev.azure.com/...",
          "attributes": {
            "name": "Parent"
          }
        }
      ]
    },
    {
      "id": 12346,
      "fields": { "...": "..." },
      "relations": null
    }
  ]
}
```

**Parse with node** to extract PR IDs and build the work-item-to-PR mapping:

```bash
node -e "
const fs = require('fs'), path = require('path'), os = require('os');
const data = JSON.parse(fs.readFileSync(path.join(os.homedir(), 'ado-flow-tmp-batch-result.json'), 'utf8'));
const wiPrMap = {};
const workItems = {};
for (const wi of data.value) {
  const id = wi.id;
  workItems[id] = wi.fields;
  wiPrMap[id] = [];
  if (wi.relations) {
    for (const rel of wi.relations) {
      if (rel.rel === 'ArtifactLink' && rel.attributes && rel.attributes.name === 'Pull Request') {
        const parts = rel.url.split('/');
        const prId = parseInt(parts[parts.length - 1], 10);
        if (!isNaN(prId)) wiPrMap[id].push(prId);
      }
    }
  }
}
console.log('Work items: ' + Object.keys(workItems).length);
const linked = Object.values(wiPrMap).flat();
console.log('PR links found: ' + linked.length + ' (unique: ' + [...new Set(linked)].length + ')');
console.log('WI_PR_MAP: ' + JSON.stringify(wiPrMap));
fs.writeFileSync(path.join(os.homedir(), 'ado-flow-tmp-wi-pr-map.json'), JSON.stringify({ wiPrMap, workItems }));
"
```

Store the output. `{WI_PR_MAP}` is the dictionary of **work item ID → list of PR IDs**.

**This replaces ALL per-PR `az repos pr work-item list` calls.** Do NOT fall back to per-PR loops under any circumstance. If `relations` is null or empty for a work item, that simply means no PRs are linked to it.

---

## Phase 3: Fetch Sprint-Scoped PRs + Reviewers (2-5 az calls, run 3a + 3b in parallel)

**Only include PRs relevant to the current sprint.** The CLI is used for fetching (it handles identity resolution), then results are filtered client-side by date and draft status. The Azure DevOps REST API does not support `isDraft` as a search criteria — filtering must be done on the response.

### 3a: Fetch Merged PRs Within Sprint (1 call)

```bash
az repos pr list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --creator "{USER_EMAIL}" \
  --status completed \
  --top 30 \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-merged-prs.json"
```

**Validate results:** If the file is empty or contains 0 PRs, the `{PR_PROJECT}` may be wrong. Warn the user: "No completed PRs found in project `{PR_PROJECT}`. Are your PRs in a different project?" and ask for the correct project name. Update the config's `pr_project` if the user provides a different one.

**Client-side filters — apply both:**
1. **Date filter:** Discard any PR where `closedDate` is before `{SPRINT_START_DATE}`. Only keep PRs completed during or after the sprint start.
2. **Draft filter:** Discard any PR where `isDraft == true`.

Build a lookup: `{MERGED_PR_MAP}` — **PR ID → {title, closedDate, repository}** for fast matching.

### 3b: Fetch Active Non-Draft PRs Within Sprint (1 call)

```bash
az repos pr list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --creator "{USER_EMAIL}" \
  --status active \
  --top 20 \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-active-prs.json"
```

**Client-side filters — apply both:**
1. **Draft filter:** Discard any PR where `isDraft == true`. Draft PRs are work-in-progress and should not trigger classification or reviewer checks.
2. **Date filter:** Discard any PR where `creationDate` is before `{SPRINT_START_DATE}`. Only keep PRs created during or after the sprint start.

Build a lookup: `{ACTIVE_PR_MAP}` — **PR ID → {title, creationDate, repository}** for fast matching. This map contains only non-draft, sprint-scoped active PRs.

### 3c: Cross-Reference (0 az calls — in-memory matching)

For each entry in `{WI_PR_MAP}`:
- If the PR ID exists in `{MERGED_PR_MAP}` → this work item has a merged PR
- If the PR ID exists in `{ACTIVE_PR_MAP}` → this work item has an active PR
- If the PR ID exists in neither → the PR was completed/created outside the sprint window, or is in a different project (ignore for classification, but do not treat as an error)

Build the final mapping: **work item ID → {merged_prs: [...], active_prs: [...]}** with full PR details.

### 3d: Fetch Reviewers — Only for Linked Active PRs (0-3 calls, parallel)

Collect the set of unique PR IDs that appear in BOTH `{WI_PR_MAP}` and `{ACTIVE_PR_MAP}`. Only these PRs need reviewer info.

For each (run sequentially, NOT in background):

```bash
az repos pr reviewer list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json 2>/dev/null
```

Classify review status per PR:
- **Awaiting review** — no votes or all votes are 0
- **Approved** — all required reviewers voted approve (vote = 10)
- **Changes requested** — any `wait-for-author` (vote = -5) or `reject` (vote = -10) vote

### 3e: Detect Unlinked PRs (0 az calls — in-memory comparison)

Collect all PR IDs referenced in `{WI_PR_MAP}` (the "linked set").

From `{MERGED_PR_MAP}` and `{ACTIVE_PR_MAP}` (already sprint-scoped from 3a/3b), identify PRs that are NOT in the linked set. These are **unlinked PRs** — PRs the user authored during this sprint that aren't connected to any sprint work item.

Since both PR lists are already filtered to the sprint window, unlinked PR detection is automatically scoped to the current sprint. No old PRs from previous sprints will appear here.

For each unlinked PR, attempt fuzzy title matching against sprint work item titles. If a reasonable match exists, suggest it.

---

## Phase 4: Auto-Classify and Present the Plan (0 az calls)

**Do not walk through items one-by-one.** Auto-classify everything, then present a single plan.

### Classification Rules

| Condition | Classification | Action |
|-----------|---------------|--------|
| Has merged PR(s) linked | **RESOLVE** | Move to `{STATE_DONE}` + comment |
| Has open PR awaiting review | **PR IN REVIEW** | Comment only |
| Has open PR with changes requested | **NEEDS ATTENTION** | Flag for input |
| `{STATE_IN_PROGRESS}` + no PRs + changed < 14 days | **IN PROGRESS** | No change |
| `{STATE_IN_PROGRESS}` + no PRs + changed > 14 days | **STALE** | Flag for input |
| `{STATE_NOT_STARTED}` + no PRs | **NOT STARTED** | No change |
| Created before `{SPRINT_START_DATE}` + still `{STATE_NOT_STARTED}` | **CARRYOVER** | Flag for input |

### Idempotency Checks

Before classifying, check for signs this command already ran:
- If an item already has a discussion comment starting with "Sprint update:", skip the comment (don't double-post).
- If an item is already in `{STATE_DONE}`, it should have been excluded by the query — but if it appears, skip it.

### Present Classification (Compact)

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
> `{CALL_COUNT} API calls | {WORK_ITEM_COUNT} items | ~{ELAPSED}s`
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
  -o json 2>/dev/null
```

Then:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_DONE}" \
  --discussion "Sprint update: PR(s) merged. {SANITIZED_PR_SUMMARY}" \
  -o json 2>/dev/null
```

**Sanitizing `--discussion`:** Strip all double quotes and backticks from PR titles and user-provided text. Wrap the entire value in double quotes. Example: `--discussion "Sprint update: PR merged - Fix null ref in auth handler"`

For PR IN REVIEW items — comment only:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --discussion "Sprint update: PR !{PR_ID} under review ({REVIEW_STATUS})." \
  -o json 2>/dev/null
```

**Error handling:** If any `az boards work-item update` returns an error (409 conflict, 400 bad request, etc.), log the error inline (`#{ID} — FAILED: {error message}`) and continue with remaining items. Never abort the batch.

After each update, confirm briefly: `#{ID} -> {STATE_DONE}` or `#{ID} comment added`

---

### Phase 4b: Items Needing Input

After bulk apply, present all items needing input together. Include unlinked PRs in the same prompt (so there is no separate Phase 5 prompt).

> Items needing input:
> 1. `#{ID6}` {TITLE} — stale 21d, no PRs
> 2. `#{ID7}` {TITLE} — carryover
> 3. `#{ID8}` {TITLE} — changes requested on PR !{PR_ID}
> 4. PR !{PR_ID} "{PR_TITLE}" — unlinked, likely match: `#{WI_ID}`
>
> Actions: **r**esolve **b**:"reason" **x**remove **s**kip **y**link
> Enter (e.g., `1s 2b:"waiting on API team" 3y`):

**Input validation:**
- Unknown item numbers -> ignore, warn: `#4 — no such item, skipped`
- Unknown action letters -> treat as skip, warn: `1z — unknown action, skipped`
- Duplicate numbers -> use last action
- Freeform text -> attempt to interpret (e.g., "skip all" = all s). If unclear, re-prompt once.
- If an update fails mid-batch -> report inline, continue.

**Parse and execute each action:**

**[r] Resolve** — with state transition safety (same as Phase 4):

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_DONE}" \
  --discussion "Sprint update: Manually resolved." \
  -o json 2>/dev/null
```

**[b:"reason"] Blocked** — if reason provided inline, use it. If just `b` with no reason, use "Flagged during sprint update."

Tags were already fetched in the Phase 2 batch response (`System.Tags` field). Use those — do not make an additional fetch.

**Tag safety:** Parse the existing tags string. If empty/null, set to `Blocked`. If non-empty, append `; Blocked` only if `Blocked` is not already present.

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --fields "System.Tags={SAFE_TAGS}" \
  --discussion "Sprint update: BLOCKED — {SANITIZED_REASON}" \
  -o json 2>/dev/null
```

**[x] Remove** — confirm once for all items marked x before executing:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{STATE_REMOVED}" \
  --discussion "Sprint update: Removed." \
  -o json 2>/dev/null
```

If no `Removed` state exists, use `{STATE_DONE}` with comment "Removed — no longer needed."

**[y] Link** — for unlinked PR items, link to the suggested work item:

```bash
az repos pr work-item add \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --work-items {WORK_ITEM_ID} \
  -o json 2>/dev/null
```

**[s] Skip** — no action.

---

### Phase 5: Handle Unlinked PRs (silent when empty)

**Skip this step entirely if all PRs are linked.** No output, no mention.

Any unlinked PRs should have already been folded into the Phase 4b batch input. This step is only needed if Phase 4b was skipped (no ambiguous items existed). In that case, present unlinked PRs:

> Unlinked PRs:
> 1. PR !{PR_ID} "{PR_TITLE}" — likely match: `#{WI_ID}`
> 2. PR !{PR_ID} "{PR_TITLE}" — no match
>
> Link? (e.g., `1y 2skip` or `2=12345`):

---

### Phase 6: Summary + Cleanup

Output the summary and diagnostics:

> Sprint update done. {N} resolved, {M} commented, {J} skipped.
> {CALL_COUNT} API calls | {WORK_ITEM_COUNT} items | ~{ELAPSED}s

Clean up temp files:

```bash
rm -f "$HOME"/ado-flow-tmp-*.json 2>/dev/null
```

**No rollback.** If the user needs to undo changes, they must use Azure DevOps history on individual work items. Mention this if an error occurs mid-batch.

---

## Data Integrity Validation

After Phase 2c (extracting PR links from relations), validate:

1. **PR ID format:** Every extracted PR ID must be a positive integer. If a relation URL doesn't match the expected `vstfs:///Git/PullRequestId/.../.../{integer}` format, log a warning and skip it.
2. **Cross-project awareness:** PR links may reference PRs in projects other than `{PR_PROJECT}`. These will simply not appear in the PR lists from Phase 3a/3b and can be safely ignored (they'll show as "PR not found in current project").
3. **Empty relations:** A work item with `relations: null` or an empty array means no PRs are linked. This is normal. Do not treat it as an error and do NOT fall back to per-PR lookups.

---

## Communication Style

- **Auto-classify first, ask questions second.** Developer confirms a plan, not builds one.
- **Bulk confirmation is the default.** Only surface items individually when they need human judgment.
- **Batch input for ambiguous items.** One response like `1s 2b:"reason"` handles everything.
- **Single-line confirmations.** `#{ID} -> Resolved` — no filler.
- **Skip means skip.** No follow-up.
- **Target: under 60 seconds, max 3 developer inputs** for a typical 10-20 item sprint.
- **Never auto-link PRs without confirmation.** Always present for user review.
- **Errors don't abort.** Log inline, continue the batch, report at the end.
- **Every run shows diagnostics.** The call count + timing line is always printed in the classification output and in the final summary.

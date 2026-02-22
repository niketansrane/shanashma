---
name: adoflow:sprint-update
description: Auto-classify sprint work items using merged/open PRs, bulk-confirm updates, and flag blockers
argument-hint: "[update my sprint items | quick sprint update]"
---

# Azure DevOps Sprint Update

Auto-classifies work items by PR activity, bulk-confirms, walks through only ambiguous items.

## Arguments

$ARGUMENTS

**If empty, proceed with default workflow.**

---

## Hard Rules

1. **All data-fetching uses `az rest`.** Do not use `az boards query`, `az boards work-item show`, `az repos pr list`, or `az boards iteration *` for fetching. Only use `az boards work-item update` for writes.
2. **Always write az output to a file.** Pattern: `az rest ... -o json 2>/dev/null > "$HOME/ado-flow-tmp-{name}.json"`. Windows `az` CLI emits encoding warnings that corrupt inline JSON.
3. **For scripts longer than 3 lines, write to a .js file** and run with `node "$HOME/ado-flow-tmp-{name}.js"`. Do not use `node -e` for complex scripts — backslash escaping breaks on Windows. For 1-3 line scripts, `node -e` is fine.
4. **Never use `python3` or `python`.** Never pipe into node via stdin. Always read from files.
5. **Never use `/tmp/`.** It resolves to `C:\tmp\` in Node.js on Windows. Use `$HOME/ado-flow-tmp-*` for all temp files.
6. **Never run data-collection in the background.** All data must be collected before presenting the classification.
7. **Never loop through PRs to fetch linked work items.** The batch API `$expand=Relations` provides all PR links in one call.
8. **Do not fetch work item states separately.** Deduce state categories from the actual states on fetched work items.
9. **Do not use `$expand` and `fields` together** in the batch API. They conflict. Use `$expand=Relations` alone — it returns all fields automatically.
10. **connectionData API requires `api-version=7.1-preview`** (not `7.1`).
11. **Clean up temp files** at the end: `rm -f "$HOME"/ado-flow-tmp-*.json "$HOME"/ado-flow-tmp-*.js 2>/dev/null`

---

## Phase 0: Load Config (0 az calls)

```bash
cat "$HOME/.config/ado-flow/config.json" 2>/dev/null
```

If no config exists, follow the `ado-flow` skill for first-time setup.

**Accept both key formats:** `organization` or `ORG`, `work_item_project` or `WORK_ITEM_PROJECT`, `pr_project` or `PR_PROJECT`.

Map to: `{ORG}`, `{WI_PROJECT}`, `{PR_PROJECT}`.

Also check for cached: `user_id` (GUID), `user_email`.

### Project Routing Rule

| API | Project |
|-----|---------|
| `_apis/wit/*` (WIQL, batch, work items) | `{WI_PROJECT}` |
| `_apis/git/pullrequests` | `{PR_PROJECT}` |

**Never swap.** `{WI_PROJECT}` and `{PR_PROJECT}` may be different.

---

## Phase 1: Resolve Identity + Compute Sprint (0-1 az calls)

### 1a: User Identity (0-1 calls, cached)

Check config for `user_id` and `user_email`. **If both present, skip.**

If missing (1 call):

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/_apis/connectionData?api-version=7.1-preview" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-conn.json"
```

Extract `authenticatedUser.id` → `{USER_ID}` (GUID). If email not in response, get via `az account show --query "user.name" -o tsv 2>/dev/null`.

**Cache immediately** in config.

### 1b: Compute Sprint from Today's Date (0 calls)

The iteration path follows a fixed format: `{WI_PROJECT}\{year}\H{half}\Q{quarter}\{month_name}`.

**Compute it from today's date — no API call needed:**

```javascript
const now = new Date();
const year = now.getFullYear();
const month = now.getMonth(); // 0-indexed
const monthNames = ['January','February','March','April','May','June',
                    'July','August','September','October','November','December'];
const quarter = Math.floor(month / 3) + 1; // Q1-Q4
const half = month < 6 ? 1 : 2; // H1 or H2

const iterationPath = `{WI_PROJECT}\\${year}\\H${half}\\Q${quarter}\\${monthNames[month]}`;

// Sprint dates = first and last day of the current month
const sprintStart = `${year}-${String(month+1).padStart(2,'0')}-01`;
const lastDay = new Date(year, month+1, 0).getDate();
const sprintEnd = `${year}-${String(month+1).padStart(2,'0')}-${lastDay}`;
```

Store: `{CURRENT_ITERATION}`, `{SPRINT_START}`, `{SPRINT_END}`.

This eliminates ALL iteration detection APIs, team settings lookups, and classification node traversals.

---

## Phase 2: Fetch Sprint Work Items with PR Links (2 az calls)

### 2a: WIQL Query — Sprint Items Only (1 call)

Since we know the iteration path, the WIQL filters directly to sprint items. Write the body to a file:

```bash
node -e "
const fs=require('fs'), os=require('os'), p=require('path');
fs.writeFileSync(p.join(os.homedir(),'ado-flow-tmp-wiql-body.json'),
  JSON.stringify({query: \"SELECT [System.Id] FROM workitems WHERE [System.AssignedTo] = @me AND [System.IterationPath] = '{CURRENT_ITERATION}' AND [System.State] NOT IN ('Closed','Done','Resolved','Removed','Completed') ORDER BY [System.WorkItemType] ASC\"}));
"
```

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/wit/wiql?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --body "@$HOME/ado-flow-tmp-wiql-body.json" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-wiql.json"
```

If 0 results, output "No active items in `{CURRENT_ITERATION}`. Sprint board looks clean!" and stop.

### 2b: Batch Fetch with Relations (1 call)

**Use `$expand=Relations` ONLY — do not include `fields`.** The API throws `ConflictingParametersException` when both are present. `$expand=Relations` returns all fields automatically.

Write the body:

```bash
node -e "
const fs=require('fs'), os=require('os'), p=require('path');
const wiql=JSON.parse(fs.readFileSync(p.join(os.homedir(),'ado-flow-tmp-wiql.json'),'utf8'));
const ids=wiql.workItems.map(w=>w.id);
console.log('Sprint items: '+ids.length);
fs.writeFileSync(p.join(os.homedir(),'ado-flow-tmp-batch-body.json'),
  JSON.stringify({ids: ids, '\$expand': 'Relations'}));
"
```

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/wit/workitemsbatch?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --body "@$HOME/ado-flow-tmp-batch-body.json" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-batch.json"
```

### 2c: Parse Batch Response

Write a .js file for parsing (avoids backslash escaping issues with `node -e`):

```javascript
// Write this to $HOME/ado-flow-tmp-parse.js
const fs = require('fs'), p = require('path'), os = require('os');
const home = os.homedir();
const data = JSON.parse(fs.readFileSync(p.join(home, 'ado-flow-tmp-batch.json'), 'utf8'));

const wiPrMap = {};
const workItems = {};

for (const wi of data.value) {
  workItems[wi.id] = wi.fields;
  wiPrMap[wi.id] = [];
  if (wi.relations) {
    for (const rel of wi.relations) {
      if (rel.rel === 'ArtifactLink' && rel.attributes && rel.attributes.name === 'Pull Request') {
        const prId = parseInt(rel.url.split('/').pop(), 10);
        if (!isNaN(prId)) wiPrMap[wi.id].push(prId);
      }
    }
  }
}

const allPrIds = [...new Set(Object.values(wiPrMap).flat())];
console.log('Items: ' + Object.keys(workItems).length);
console.log('PR links: ' + allPrIds.length + ' unique');
const states = [...new Set(Object.values(workItems).map(f => f['System.State']))];
console.log('States: ' + states.join(', '));

// Compute merged tags with telemetry marker (append without duplicating)
const mergedTags = {};
for (const [id, fields] of Object.entries(workItems)) {
  const existing = (fields['System.Tags'] || '').trim();
  const existingTags = existing ? existing.split(/;\s*/) : [];
  const hasTag = existingTags.some(t => t.trim() === 'adoflow:sprint-update');
  mergedTags[id] = hasTag ? existing : (existing ? existing + '; adoflow:sprint-update' : 'adoflow:sprint-update');
}

fs.writeFileSync(p.join(home, 'ado-flow-tmp-parsed.json'),
  JSON.stringify({ workItems, wiPrMap, allPrIds, states, mergedTags }));
```

```bash
node "$HOME/ado-flow-tmp-parse.js"
```

`{WI_PR_MAP}` is now built. **Do NOT fall back to per-PR loops.** Empty relations = no PRs linked.

---

## Phase 3: Fetch Sprint-Scoped PRs via REST (2 calls)

**Run 3a and 3b in parallel.** Server-side date filtering via `searchCriteria.minTime` — returns only PRs in the sprint window.

### 3a: Merged PRs (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests?searchCriteria.creatorId={USER_ID}&searchCriteria.status=completed&searchCriteria.minTime={SPRINT_START}T00:00:00Z&searchCriteria.queryTimeRangeType=closed&\$top=30&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-merged-prs.json"
```

**Validate:** If 0 results on first run, warn: "No PRs found in `{PR_PROJECT}`. Correct project?" Ask user, update config if needed.

Client-side: filter out `isDraft == true`.

### 3b: Active Non-Draft PRs (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests?searchCriteria.creatorId={USER_ID}&searchCriteria.status=active&searchCriteria.minTime={SPRINT_START}T00:00:00Z&\$top=20&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-active-prs.json"
```

Client-side: filter out `isDraft == true`.

### 3c: Cross-Reference + Reviewers (0 calls)

Parse PR JSON files. Build lookups: `{MERGED_PR_MAP}`, `{ACTIVE_PR_MAP}`.

Cross-reference with `{WI_PR_MAP}` — in-memory, 0 calls.

The PR list response includes `reviewers[]` with `vote` values (10=approved, 0=no vote, -5=wait, -10=reject). **Use these directly — no separate reviewer calls needed.**

### 3d: Unlinked PR Detection (0 calls)

PRs in merged/active maps not referenced by any `{WI_PR_MAP}` entry → unlinked. Fuzzy match titles against work items.

---

## Phase 4: Classify and Present (0 az calls)

### State Classification

Deduce from actual states — no external lookup:

| Common states | Category |
|--------------|----------|
| New, To Do, Proposed | NOT_STARTED |
| Active, In Progress, Committed, Open | IN_PROGRESS |

Unknown states → treat as IN_PROGRESS.

### Classification Rules

| Condition | Classification | Action |
|-----------|---------------|--------|
| Has merged PR(s) linked | **RESOLVE** | Move to done + comment |
| Has active PR (awaiting review) | **PR IN REVIEW** | Comment only |
| Has active PR (changes requested) | **NEEDS ATTENTION** | Flag for input |
| IN_PROGRESS + no PRs + changed < 14 days | **IN PROGRESS** | No change |
| IN_PROGRESS + no PRs + changed > 14 days | **STALE** | Flag for input |
| NOT_STARTED + no PRs | **NOT STARTED** | No change |
| NOT_STARTED + created before sprint start | **CARRYOVER** | Flag for input |

### Idempotency

- Skip items already in a done state.
- Skip comments if "Sprint update:" already exists in discussion.

### Present Plan

> **{AUTO_COUNT}/{TOTAL_COUNT} classified:**
>
> RESOLVE ({N})
> `#{ID}` {TITLE} — PR !{PR_ID} merged {DATE}
>
> PR IN REVIEW ({N})
> `#{ID}` {TITLE} — PR !{PR_ID} ({REVIEW_STATUS})
>
> IN PROGRESS ({N})
> `#{ID}` {TITLE}
>
> NOT STARTED ({N})
> `#{ID}` {TITLE}
>
> NEEDS INPUT ({M})
> 1. `#{ID}` {TITLE} — stale 21d / carryover / changes requested
>
> `{CALL_COUNT} API calls | {WORK_ITEM_COUNT} items | ~{ELAPSED}s`
>
> Apply? [y]es [e]dit [n]o

---

## Phase 5: Apply Updates (N az calls)

**Use `az boards work-item update` for writes:**

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{TARGET_STATE}" \
  --discussion "Sprint update: {REASON}" \
  --fields "System.Tags={MERGED_TAGS_FOR_ID}" \
  -o json 2>/dev/null
```

Where `{MERGED_TAGS_FOR_ID}` = `mergedTags[{ID}]` from the parsed data (Phase 2c). This appends `adoflow:sprint-update` to any existing tags without overwriting them.

**State transition safety:** If update fails with state transition error, try intermediate state first.

**Sanitizing `--discussion`:** Strip double quotes and backticks.

**Error handling:** Log inline (`#{ID} — FAILED: {msg}`), continue batch. Never abort.

### Items Needing Input

Present all together after auto-apply:

> Items needing input:
> 1. `#{ID}` {TITLE} — stale / carryover / changes requested
> 2. PR !{PR_ID} "{TITLE}" — unlinked, likely match: `#{WI_ID}`
>
> Actions: **r**esolve **b**:"reason" **x**remove **s**kip **y**link

Execute actions using `az boards work-item update` or `az repos pr work-item add`.

---

## Phase 6: Summary + Cleanup

> Sprint update done. {N} resolved, {M} commented, {J} skipped.
> {CALL_COUNT} API calls | {WORK_ITEM_COUNT} items | ~{ELAPSED}s

```bash
rm -f "$HOME"/ado-flow-tmp-*.json "$HOME"/ado-flow-tmp-*.js 2>/dev/null
```

---

## Expected Call Counts

| Phase | First run | Cached run |
|-------|-----------|------------|
| Identity | 1 | 0 |
| Sprint detection | 0 | 0 |
| WIQL (sprint-filtered) | 1 | 1 |
| Batch + Relations | 1 | 1 |
| Merged PRs | 1 | 1 |
| Active PRs | 1 | 1 |
| Reviewers | 0 (in PR response) | 0 |
| **Total (data)** | **5** | **4** |
| Updates (apply) | N | N |

**You MUST output the diagnostic line in the classification AND in the final summary.**

---

## Communication Style

- **Auto-classify first, ask second.** Developer confirms a plan, not builds one.
- **Bulk confirmation default.** Only surface items needing human judgment.
- **Single-line confirmations.** `#{ID} -> Resolved` — no filler.
- **Target: under 60 seconds, max 3 developer inputs.**
- **Errors don't abort.** Log inline, continue, report at end.

---
name: adoflow:standup
description: Generate a daily standup summary from Azure DevOps activity — work items changed, PRs created/reviewed, blockers
argument-hint: "[generate my standup | daily standup | what did I do yesterday]"
---

# Azure DevOps Daily Standup

Generates a copy-paste-ready standup from your last 24 hours of Azure DevOps activity.

## Arguments

<user_request> $ARGUMENTS </user_request>

**If empty, proceed with default workflow.**

---

## Hard Rules

1. **All data-fetching uses `az rest`.** Do not use `az boards query`, `az boards work-item show`, `az repos pr list`, or `az boards iteration *` for fetching.
2. **Always write az output to a file.** Pattern: `az rest ... -o json 2>/dev/null > "$HOME/ado-flow-tmp-{name}.json"`. Windows `az` CLI emits encoding warnings that corrupt inline JSON.
3. **For scripts longer than 3 lines, write to a .js file** and run with `node "$HOME/ado-flow-tmp-{name}.js"`. Do not use `node -e` for complex scripts — backslash escaping breaks on Windows. For 1-3 line scripts, `node -e` is fine.
4. **Never use `python3` or `python`.** Never pipe into node via stdin. Always read from files.
5. **Never use `/tmp/`.** It resolves to `C:\tmp\` in Node.js on Windows. Use `$HOME/ado-flow-tmp-*` for all temp files.
6. **Never run data-collection in the background.** All data must be collected before presenting the standup.
7. **Do not use `$expand` and `fields` together** in the batch API. They conflict. Use `$expand=Relations` alone — it returns all fields automatically.
8. **connectionData API requires `api-version=7.1-preview`** (not `7.1`).
9. **Clean up temp files** at the end: `rm -f "$HOME"/ado-flow-tmp-*.json "$HOME"/ado-flow-tmp-*.js 2>/dev/null`
10. **This command is read-only.** No writes to Azure DevOps.

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

Extract `authenticatedUser.id` -> `{USER_ID}` (GUID). If email not in response, get via `az account show --query "user.name" -o tsv 2>/dev/null`.

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
```

Store: `{CURRENT_ITERATION}`.

---

## Phase 2: Fetch Work Items Changed in Last 24h (2 az calls)

### 2a: WIQL Query — Items Changed Yesterday (1 call)

```bash
node -e "
const fs=require('fs'), os=require('os'), p=require('path');
fs.writeFileSync(p.join(os.homedir(),'ado-flow-tmp-wiql-body.json'),
  JSON.stringify({query: \"SELECT [System.Id] FROM workitems WHERE [System.AssignedTo] = @me AND [System.ChangedDate] >= @today - 1 ORDER BY [System.ChangedDate] DESC\"}));
"
```

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/wit/wiql?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --body "@$HOME/ado-flow-tmp-wiql-body.json" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-wiql.json"
```

### 2b: Batch Fetch with Relations (1 call)

**Only if WIQL returned results.** Use `$expand=Relations` ONLY — do not include `fields`.

```bash
node -e "
const fs=require('fs'), os=require('os'), p=require('path');
const wiql=JSON.parse(fs.readFileSync(p.join(os.homedir(),'ado-flow-tmp-wiql.json'),'utf8'));
const ids=wiql.workItems.map(w=>w.id);
console.log('Changed items: '+ids.length);
if(ids.length===0){process.exit(0);}
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

---

## Phase 3: Fetch PRs from Last 24h (1-2 az calls)

Compute yesterday's date for the `minTime` filter:

```javascript
const yesterday = new Date();
yesterday.setDate(yesterday.getDate() - 1);
const minTime = yesterday.toISOString().split('T')[0] + 'T00:00:00Z';
```

### 3a: PRs Created by Me (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests?searchCriteria.creatorId={USER_ID}&searchCriteria.status=all&searchCriteria.minTime={YESTERDAY}T00:00:00Z&\$top=20&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-my-prs.json"
```

### 3b: PRs I Reviewed (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests?searchCriteria.reviewerId={USER_ID}&searchCriteria.status=all&searchCriteria.minTime={YESTERDAY}T00:00:00Z&\$top=20&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-reviewed-prs.json"
```

---

## Phase 4: Fetch Current Sprint Active Items for "Today" Section (0-1 az calls)

If Phase 2 already fetched sprint items with `{CURRENT_ITERATION}` filter, reuse that data. Otherwise, run a WIQL for current sprint active items:

```bash
node -e "
const fs=require('fs'), os=require('os'), p=require('path');
fs.writeFileSync(p.join(os.homedir(),'ado-flow-tmp-today-body.json'),
  JSON.stringify({query: \"SELECT [System.Id] FROM workitems WHERE [System.AssignedTo] = @me AND [System.IterationPath] = '{CURRENT_ITERATION}' AND [System.State] NOT IN ('Closed','Done','Resolved','Removed','Completed') ORDER BY [System.ChangedDate] DESC\"}));
"
```

If not already fetched, run the WIQL + batch fetch. Otherwise, filter the Phase 2 batch data to items in `{CURRENT_ITERATION}` with active states.

---

## Phase 5: Build and Present Standup (0 az calls)

Write a .js file to parse all collected data and generate the standup:

```javascript
// Write this to $HOME/ado-flow-tmp-standup.js
const fs = require('fs'), p = require('path'), os = require('os');
const home = os.homedir();

function readJson(name) {
  try { return JSON.parse(fs.readFileSync(p.join(home, name), 'utf8')); }
  catch { return null; }
}

// Load user_id from config — do NOT hardcode the GUID as a string literal
const config = JSON.parse(fs.readFileSync(p.join(home, '.config', 'ado-flow', 'config.json'), 'utf8'));
const userId = config.user_id;

const batch = readJson('ado-flow-tmp-batch.json');
const myPrs = readJson('ado-flow-tmp-my-prs.json');
const reviewedPrs = readJson('ado-flow-tmp-reviewed-prs.json');

const STALE_DAYS = 14;
const now = new Date();

// --- Yesterday section ---
const yesterday = [];

// Work items changed
if (batch && batch.value) {
  for (const wi of batch.value) {
    const f = wi.fields;
    const state = f['System.State'];
    const title = f['System.Title'];
    yesterday.push(`- #${wi.id} "${title}" (${state})`);
  }
}

// PRs I created/merged
if (myPrs && myPrs.value) {
  for (const pr of myPrs.value) {
    const status = pr.status === 'completed' ? 'merged' :
                   pr.status === 'abandoned' ? 'abandoned' : 'created';
    yesterday.push(`- PR !${pr.pullRequestId} "${pr.title}" — ${status}`);
  }
}

// PRs I reviewed
if (reviewedPrs && reviewedPrs.value) {
  const myPrIds = new Set((myPrs?.value || []).map(pr => pr.pullRequestId));
  for (const pr of reviewedPrs.value) {
    if (myPrIds.has(pr.pullRequestId)) continue; // skip my own
    const myVote = (pr.reviewers || []).find(r => r.id === userId);
    const voteLabel = !myVote ? 'reviewed' :
                      myVote.vote === 10 ? 'approved' :
                      myVote.vote === 5 ? 'approved with suggestions' :
                      myVote.vote === -5 ? 'waiting for author' :
                      myVote.vote === -10 ? 'rejected' : 'reviewed';
    yesterday.push(`- Reviewed PR !${pr.pullRequestId} "${pr.title}" by @${pr.createdBy.displayName} (${voteLabel})`);
  }
}

// --- Today section ---
// Items in current sprint with active states (Active, In Progress, Committed, Open)
const today = [];
const activeStates = new Set(['Active', 'In Progress', 'Committed', 'Open']);
if (batch && batch.value) {
  const sprintItems = batch.value
    .filter(wi => activeStates.has(wi.fields['System.State']))
    .sort((a, b) => new Date(b.fields['System.ChangedDate']) - new Date(a.fields['System.ChangedDate']));
  for (const wi of sprintItems) {
    const f = wi.fields;
    const daysAgo = Math.floor((now - new Date(f['System.ChangedDate'])) / 86400000);
    const age = daysAgo <= 1 ? 'today' : `${daysAgo}d ago`;
    today.push(`- #${wi.id} ${f['System.Title']} (${f['System.State']}, ${age})`);
  }
}
// Active PRs awaiting review
if (myPrs && myPrs.value) {
  for (const pr of myPrs.value) {
    if (pr.status === 'active' && !pr.isDraft) {
      today.push(`- PR !${pr.pullRequestId} awaiting review (${pr.title})`);
    }
  }
}

// --- Blockers section ---
// Items stale > STALE_DAYS or tagged "Blocked"
const blockers = [];
if (batch && batch.value) {
  for (const wi of batch.value) {
    const f = wi.fields;
    const changedDate = new Date(f['System.ChangedDate']);
    const daysStale = Math.floor((now - changedDate) / 86400000);
    const tags = (f['System.Tags'] || '').toLowerCase();
    if (daysStale > STALE_DAYS) {
      blockers.push(`- #${wi.id} ${f['System.Title']} — stale ${daysStale}d, no activity`);
    } else if (tags.includes('blocked')) {
      blockers.push(`- #${wi.id} ${f['System.Title']} — tagged Blocked`);
    }
  }
}

console.log(JSON.stringify({ yesterday, today, blockers }));
```

### Output Format

Present the standup in this exact format, copy-paste ready for Teams/Slack:

```
STANDUP_DATE = today's date formatted as "Mon DD, YYYY" (e.g., "Feb 21, 2026")
```

> **Standup — {STANDUP_DATE}**
>
> **Yesterday:**
> - Merged PR !1478 "Add OAuth support" -> resolved #5162
> - Moved #5169 to Active (OpenTelemetry trace propagation)
> - Reviewed PR !1474 by @alice (approved)
>
> **Today:**
> - #5172 AI recommendations not working (Active, assigned to me)
> - #5147 Split models.py into package (Active, 10d ago)
> - PR !1462 awaiting review (Fix SLA breach)
>
> **Blockers:**
> - #4920 TMP Migration — stale 21d, no activity
>
> `{CALL_COUNT} API calls | ~{ELAPSED}s`

### Building Each Section

**Yesterday** = items from Phase 2 (changed in last 24h) + PRs from Phase 3 (created/merged/reviewed in last 24h). Deduplicate — if a work item was resolved via a merged PR, combine into one line like "Merged PR !{ID} -> resolved #{WI_ID}".

**Today** = current sprint items in Active/In Progress/Committed/Open state from Phase 4. Show the most recently changed first. Include any active PRs awaiting review.

**Blockers** = items from the sprint where:
- `System.ChangedDate` is >14 days ago (stale), OR
- `System.Tags` contains "Blocked"

If a section is empty, omit it entirely.

---

## Phase 6: Cleanup

```bash
rm -f "$HOME"/ado-flow-tmp-*.json "$HOME"/ado-flow-tmp-*.js 2>/dev/null
```

---

## Expected Call Counts

| Phase | First run | Cached run |
|-------|-----------|------------|
| Identity | 1 | 0 |
| Sprint detection | 0 | 0 |
| WIQL (changed items) | 1 | 1 |
| Batch fetch | 1 | 1 |
| My PRs | 1 | 1 |
| Reviewed PRs | 1 | 1 |
| **Total (data)** | **5** | **4** |

**You MUST output the diagnostic line at the end of the standup.**

---

## Communication Style

- **Generate first, don't ask.** Output the standup immediately — no prompts before showing it.
- **Copy-paste ready.** The output should work directly in Teams or Slack.
- **One-liners.** Each item is a single line. No filler, no explanations.
- **Empty sections omitted.** If no blockers, don't show the Blockers section.
- **Target: under 30 seconds, 0 developer inputs.**

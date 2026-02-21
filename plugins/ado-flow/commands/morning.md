---
name: adoflow:morning
description: Morning briefing — review queue, your PR status, sprint progress, pipeline health, and action items
argument-hint: "[morning briefing | what should I work on | daily overview]"
---

# Azure DevOps Morning Briefing

Combines your review queue, PR status, sprint progress, pipeline health, and prioritized action items into one view.

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
6. **Never run data-collection in the background.** All data must be collected before presenting the briefing.
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
| `_apis/build/builds` | `{PR_PROJECT}` |

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

// Sprint dates = first and last day of the current month
const sprintStart = `${year}-${String(month+1).padStart(2,'0')}-01`;
const lastDay = new Date(year, month+1, 0).getDate();
const sprintEnd = `${year}-${String(month+1).padStart(2,'0')}-${lastDay}`;
```

Store: `{CURRENT_ITERATION}`, `{SPRINT_START}`, `{SPRINT_END}`.

Compute yesterday's date for time filters:

```javascript
const yesterday = new Date();
yesterday.setDate(yesterday.getDate() - 1);
const minTime = yesterday.toISOString().split('T')[0] + 'T00:00:00Z';
```

Store: `{YESTERDAY_ISO}`.

---

## Phase 2: Fetch Review Queue + My PRs (2 az calls, run in parallel)

### 2a: PRs Awaiting My Review (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests?searchCriteria.reviewerId={USER_ID}&searchCriteria.status=active&\$top=20&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-review-queue.json"
```

Client-side filter: only include PRs where my vote == 0 (haven't reviewed yet) or vote == -5 (waiting for author, but author has pushed new changes). Exclude PRs created by me.

### 2b: My Active PRs (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests?searchCriteria.creatorId={USER_ID}&searchCriteria.status=active&\$top=20&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-my-prs.json"
```

---

## Phase 3: Fetch Sprint Work Items (2 az calls)

### 3a: WIQL Query — Sprint Items (1 call)

```bash
node -e "
const fs=require('fs'), os=require('os'), p=require('path');
fs.writeFileSync(p.join(os.homedir(),'ado-flow-tmp-wiql-body.json'),
  JSON.stringify({query: \"SELECT [System.Id] FROM workitems WHERE [System.AssignedTo] = @me AND [System.IterationPath] = '{CURRENT_ITERATION}' ORDER BY [System.State] ASC\"}));
"
```

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/wit/wiql?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --body "@$HOME/ado-flow-tmp-wiql-body.json" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-wiql.json"
```

### 3b: Batch Fetch (1 call)

**Only if WIQL returned results.** Use `$expand=Relations` ONLY.

```bash
node -e "
const fs=require('fs'), os=require('os'), p=require('path');
const wiql=JSON.parse(fs.readFileSync(p.join(os.homedir(),'ado-flow-tmp-wiql.json'),'utf8'));
const ids=wiql.workItems.map(w=>w.id);
console.log('Sprint items: '+ids.length);
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

## Phase 4: Fetch Pipeline Builds (1 az call)

### 4a: Recent Builds by Me (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/build/builds?requestedFor={USER_EMAIL}&minTime={YESTERDAY_ISO}&\$top=10&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-builds.json"
```

**Note:** Use `{USER_EMAIL}` for `requestedFor` (display name or email, not GUID). If that returns 0 results, the filter may need `requestedFor` as display name — log but don't fail.

---

## Phase 5: Build and Present Briefing (0 az calls)

Write a .js file to parse all collected data and generate the briefing:

```javascript
// Write this to $HOME/ado-flow-tmp-morning.js
const fs = require('fs'), p = require('path'), os = require('os');
const home = os.homedir();

function readJson(name) {
  try { return JSON.parse(fs.readFileSync(p.join(home, name), 'utf8')); }
  catch { return null; }
}

// Load user_id from config — do NOT hardcode the GUID as a string literal
const config = JSON.parse(fs.readFileSync(p.join(home, '.config', 'ado-flow', 'config.json'), 'utf8'));
const userId = config.user_id;

const reviewQueueRaw = readJson('ado-flow-tmp-review-queue.json');
const myPrsRaw = readJson('ado-flow-tmp-my-prs.json');
const batch = readJson('ado-flow-tmp-batch.json');
const buildsRaw = readJson('ado-flow-tmp-builds.json');

const now = new Date();
const STALE_DAYS = 14;

function daysAgo(dateStr) {
  return Math.floor((now - new Date(dateStr)) / 86400000);
}
function relativeTime(dateStr) {
  const d = daysAgo(dateStr);
  if (d === 0) return 'today';
  if (d === 1) return 'yesterday';
  return `${d}d ago`;
}

// --- Review Queue: PRs where my vote == 0, not created by me, sorted oldest first ---
const reviewQueue = [];
if (reviewQueueRaw && reviewQueueRaw.value) {
  for (const pr of reviewQueueRaw.value) {
    if (pr.createdBy && pr.createdBy.id === userId) continue;
    const myReview = (pr.reviewers || []).find(r => r.id === userId);
    if (!myReview || myReview.vote === 0) {
      const waiting = daysAgo(pr.creationDate);
      reviewQueue.push({ id: pr.pullRequestId, title: pr.title,
        author: pr.createdBy?.displayName || 'unknown', waiting, urgent: waiting >= 3 });
    }
  }
  reviewQueue.sort((a, b) => b.waiting - a.waiting); // oldest first
}

// --- My PRs: summarize review status ---
const myPrs = [];
if (myPrsRaw && myPrsRaw.value) {
  for (const pr of myPrsRaw.value) {
    if (pr.isDraft) continue;
    const reviewers = pr.reviewers || [];
    const approvals = reviewers.filter(r => r.vote >= 5).length;
    const rejections = reviewers.filter(r => r.vote <= -5);
    let status;
    if (rejections.length > 0) {
      status = `changes requested by @${rejections[0].displayName}`;
    } else if (approvals > 0 && rejections.length === 0) {
      status = `${approvals} approval${approvals > 1 ? 's' : ''}, ready to merge`;
    } else {
      status = 'awaiting review';
    }
    myPrs.push({ id: pr.pullRequestId, title: pr.title, status });
  }
}

// --- Sprint Progress: categorize by state ---
const doneStates = new Set(['Closed', 'Done', 'Resolved', 'Completed']);
const activeStates = new Set(['Active', 'In Progress', 'Committed', 'Open']);
const newStates = new Set(['New', 'To Do', 'Proposed']);
let done = 0, inProgress = 0, notStarted = 0, needsAttention = 0, total = 0;
const staleItems = [];
if (batch && batch.value) {
  total = batch.value.length;
  for (const wi of batch.value) {
    const f = wi.fields;
    const state = f['System.State'];
    const tags = (f['System.Tags'] || '').toLowerCase();
    const stale = daysAgo(f['System.ChangedDate']) > STALE_DAYS;
    if (stale || tags.includes('blocked')) {
      needsAttention++;
      staleItems.push({ id: wi.id, title: f['System.Title'],
        days: daysAgo(f['System.ChangedDate']), blocked: tags.includes('blocked') });
    } else if (doneStates.has(state)) { done++; }
    else if (activeStates.has(state)) { inProgress++; }
    else if (newStates.has(state)) { notStarted++; }
    else { notStarted++; }
  }
}
const pct = total > 0 ? Math.round(done / total * 100) : 0;
const barLen = 16;
const filled = Math.round(pct / 100 * barLen);
const progressBar = '\u2588'.repeat(filled) + '\u2591'.repeat(barLen - filled);

// --- Pipelines: format results ---
const pipelines = [];
if (buildsRaw && buildsRaw.value) {
  for (const b of buildsRaw.value) {
    const emoji = b.result === 'succeeded' ? '\u2705' :
                  b.result === 'failed' ? '\u274C' :
                  b.result === 'partiallySucceeded' ? '\u26A0\uFE0F' :
                  b.result === 'canceled' ? '\u23F9' :
                  b.status === 'inProgress' ? '\u23F3' : '\u2753';
    pipelines.push({ name: b.definition?.name || 'unknown', number: b.buildNumber,
      emoji, result: b.result || b.status, branch: b.sourceBranch?.replace('refs/heads/', '') || '',
      time: relativeTime(b.finishTime || b.startTime) });
  }
}

// --- Action Items: auto-prioritized ---
const actions = [];
for (const pr of reviewQueue) {
  actions.push(`Review PR !${pr.id} (waiting ${pr.waiting}d${pr.urgent ? ' — blocking @' + pr.author : ''})`);
}
for (const p of pipelines) {
  if (p.result === 'failed') {
    actions.push(`Check pipeline failure: ${p.name} on ${p.branch}`);
  }
}
if (staleItems.length > 0) {
  const ids = staleItems.map(s => '#' + s.id).join(', ');
  actions.push(`${staleItems.length} stale item${staleItems.length > 1 ? 's' : ''} need attention (${ids})`);
}
for (const pr of myPrs) {
  if (pr.status.includes('ready to merge')) {
    actions.push(`Merge PR !${pr.id} (${pr.title})`);
  }
}

console.log(JSON.stringify({
  reviewQueue, myPrs, sprint: { total, done, inProgress, notStarted, needsAttention, pct, progressBar },
  pipelines, staleItems, actions
}));
```

```bash
node "$HOME/ado-flow-tmp-morning.js"
```

### Output Format

Present the briefing in this exact format:

> **Morning Briefing — {DATE}**
>
> **Review Queue ({N} PRs waiting for you):**
> - PR !{ID} "{TITLE}" by @{AUTHOR} — waiting {N}d {WARNING_IF_3D+}
> - PR !{ID} "{TITLE}" by @{AUTHOR} — waiting {N}d
>
> **Your PRs:**
> - PR !{ID} "{TITLE}" — {APPROVALS} approvals, ready to merge
> - PR !{ID} "{TITLE}" — changes requested by @{REVIEWER}
> - PR !{ID} "{TITLE}" — merged yesterday
>
> **Sprint Progress ({MONTH_NAME}):**
> - {TOTAL} items: {DONE} done, {IN_PROGRESS} in progress, {NOT_STARTED} not started, {NEEDS_ATTENTION} need attention
> - {PROGRESS_BAR} {PERCENT}% complete
>
> **Pipelines:**
> - {PIPELINE_NAME} #{BUILD_NUMBER} — {RESULT_EMOJI} {RESULT} ({BRANCH}, {TIME_AGO})
>
> **Action items:**
> 1. Review PR !{ID} (waiting {N}d — blocking @{AUTHOR})
> 2. Check pipeline failure on {BRANCH}
> 3. {N} stale items need attention (#{ID}, #{ID})
>
> `{CALL_COUNT} API calls | ~{ELAPSED}s`

### Building Each Section

**Review Queue:** PRs from Phase 2a where my vote == 0, excluding PRs I created. Sort by creation date ascending (oldest first = most urgent). Add warning emoji for PRs waiting 3+ days. Exclude draft PRs.

**Your PRs:** PRs from Phase 2b. Summarize review status:
- All approvals, no rejections -> "ready to merge"
- Has rejections or "wait for author" -> "changes requested by @{name}"
- No reviews yet -> "awaiting review"

**Sprint Progress:** From Phase 3 batch data. Categorize by state:
- Done states: Closed, Done, Resolved, Completed -> done
- Active states: Active, In Progress, Committed, Open -> in progress
- New states: New, To Do, Proposed -> not started
- Stale (>14d no change) or tagged "Blocked" -> need attention

Progress bar: 16 chars wide, filled proportionally. `done / total * 100` = percent.

```
Progress bar chars: filled = █ (U+2588, FULL BLOCK), empty = ░ (U+2591, LIGHT SHADE)
Example: ██████░░░░░░░░░░ 37% complete
```

**Pipelines:** From Phase 4. Show result with emoji:
- `succeeded` -> green checkmark
- `failed` -> red X
- `partiallySucceeded` -> warning
- `canceled` -> canceled
- `inProgress` -> running

Show branch name and relative time ("2h ago", "yesterday").

**Action Items:** Automatically prioritized list:
1. PRs waiting for my review (oldest first, especially 3+ days)
2. Pipeline failures on my branches
3. Stale work items (>14d no change)
4. PRs ready to merge (just need the button click)

If a section has 0 items, omit it entirely (except Sprint Progress, always show that).

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
| Review queue PRs | 1 | 1 |
| My active PRs | 1 | 1 |
| WIQL (sprint items) | 1 | 1 |
| Batch fetch | 1 | 1 |
| Pipeline builds | 1 | 1 |
| **Total (data)** | **6** | **5** |

**You MUST output the diagnostic line at the end of the briefing.**

---

## Communication Style

- **Generate first, don't ask.** Output the full briefing immediately — no prompts.
- **Action items are the hook.** The numbered list at the bottom tells the developer what to do first.
- **Compact but complete.** Every section is a quick scan. No paragraphs.
- **Emoji for quick scanning.** Red/green/warning indicators for pipeline status and review urgency.
- **Target: under 45 seconds, 0 developer inputs.**

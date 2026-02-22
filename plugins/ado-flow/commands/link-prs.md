---
name: adoflow-link-prs
description: Find unlinked PRs in the current sprint and link them to matching work items
argument-hint: "[link unlinked PRs | find orphan PRs | link my PRs to work items]"
---

# Azure DevOps Link PRs

Finds PRs in the current sprint that are not linked to any work item, matches them using branch names / titles / descriptions, and links them with confirmation.

**Read/write command.** This command creates PR-to-work-item links in Azure DevOps. Requires `vso.code_write` and `vso.work_write` scopes.

## Arguments

$ARGUMENTS

**If empty, proceed with default workflow.**

---

## Hard Rules

1. **All data-fetching uses `az rest`.** Do not use `az boards query`, `az boards work-item show`, `az repos pr list`, or `az boards iteration *` for fetching. Only use `az boards work-item update` for writes. Use `az repos pr work-item add` for linking.
2. **Always write az output to a file.** Pattern: `az rest ... -o json 2>/dev/null > "$HOME/ado-flow-tmp-{name}.json"`. Windows `az` CLI emits encoding warnings that corrupt inline JSON.
3. **For scripts longer than 3 lines, write to a .js file** and run with `node "$HOME/ado-flow-tmp-{name}.js"`. Do not use `node -e` for complex scripts — backslash escaping breaks on Windows. For 1-3 line scripts, `node -e` is fine.
4. **Never use `python3` or `python`.** Never pipe into node via stdin. Always read from files.
5. **Never use `/tmp/`.** It resolves to `C:\tmp\` in Node.js on Windows. Use `$HOME/ado-flow-tmp-*` for all temp files.
6. **Never run data-collection in the background.** All data must be collected before presenting matches.
7. **Do not use `$expand` and `fields` together** in the batch API. They conflict. Use `$expand=Relations` alone — it returns all fields automatically.
8. **connectionData API requires `api-version=7.1-preview`** (not `7.1`).
9. **Clean up temp files** at the end: `rm -f "$HOME"/ado-flow-tmp-*.json "$HOME"/ado-flow-tmp-*.js 2>/dev/null`
10. **Never loop through PRs to fetch linked work items.** The batch API `$expand=Relations` provides all PR links in one call.
11. **Always include `--headers "Content-Type=application/json"` on every `az rest --method post` call.** Without it, Azure DevOps returns HTTP 400 (`VssRequestContentTypeNotSupportedException`).
12. **Never embed iteration paths with backslashes in `node -e` strings.** Write WIQL/batch body generation to a `.js` file. Construct paths using `String.fromCharCode(92)` for the backslash separator. Same for any JSON key containing `$` (like `$expand`) — use `.js` files to avoid shell variable expansion.
13. **If `--body @"$HOME/..."` fails on Windows,** use `--body @"$(cygpath -w "$HOME/ado-flow-tmp-{name}.json")"` to convert to a Windows-native path.
14. **After each `az rest` call writing to a file, verify the file is non-empty.** If 0 bytes, re-run without `2>/dev/null` to diagnose.

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

// Sprint dates = first and last day of the current month
const sprintStart = `${year}-${String(month+1).padStart(2,'0')}-01`;
const lastDay = new Date(year, month+1, 0).getDate();
const sprintEnd = `${year}-${String(month+1).padStart(2,'0')}-${lastDay}`;
```

Store: `{CURRENT_ITERATION}`, `{SPRINT_START}`, `{SPRINT_END}`.

---

## Phase 2: Fetch Sprint Work Items with PR Links (2 az calls)

### 2a: WIQL Query — Sprint Items (1 call)

Write `$HOME/ado-flow-tmp-wiql-gen.js`:

```javascript
// $HOME/ado-flow-tmp-wiql-gen.js
const fs = require('fs'), os = require('os'), p = require('path');
const bs = String.fromCharCode(92); // backslash
const iterPath = ['{WI_PROJECT}','{YEAR}','H{HALF}','Q{QUARTER}','{MONTH_NAME}'].join(bs);
const query = `SELECT [System.Id] FROM workitems WHERE [System.AssignedTo] = @me AND [System.IterationPath] = '${iterPath}' ORDER BY [System.WorkItemType] ASC`;
fs.writeFileSync(p.join(os.homedir(), 'ado-flow-tmp-wiql-body.json'), JSON.stringify({ query }));
```

```bash
node "$HOME/ado-flow-tmp-wiql-gen.js"
```

Note: Include ALL states (not just active) — we want to link PRs to resolved items too.

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/wit/wiql?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --headers "Content-Type=application/json" \
  --body "@$HOME/ado-flow-tmp-wiql-body.json" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-wiql.json"
```

If 0 results, output "No items in `{CURRENT_ITERATION}`. Nothing to link." and stop.

### 2b: Batch Fetch with Relations (1 call)

**Use `$expand=Relations` ONLY — do not include `fields`.**

Write `$HOME/ado-flow-tmp-batch-gen.js`:

```javascript
// $HOME/ado-flow-tmp-batch-gen.js
const fs = require('fs'), os = require('os'), p = require('path');
const wiql = JSON.parse(fs.readFileSync(p.join(os.homedir(), 'ado-flow-tmp-wiql.json'), 'utf8'));
const ids = wiql.workItems.map(w => w.id);
console.log('Sprint items: ' + ids.length);
if (ids.length === 0) { process.exit(0); }
const body = { ids };
body['$expand'] = 'Relations';
fs.writeFileSync(p.join(os.homedir(), 'ado-flow-tmp-batch-body.json'), JSON.stringify(body));
```

```bash
node "$HOME/ado-flow-tmp-batch-gen.js"
```

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/wit/workitemsbatch?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --headers "Content-Type=application/json" \
  --body "@$HOME/ado-flow-tmp-batch-body.json" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-batch.json"
```

### 2c: Parse and Build Work Item + PR Link Maps

Write a .js file for parsing:

```javascript
// Write this to $HOME/ado-flow-tmp-parse-wi.js
const fs = require('fs'), p = require('path'), os = require('os');
const home = os.homedir();
const data = JSON.parse(fs.readFileSync(p.join(home, 'ado-flow-tmp-batch.json'), 'utf8'));

const workItems = {}; // id -> { title, state }
const linkedPrIds = new Set(); // PR IDs already linked to work items

for (const wi of data.value) {
  workItems[wi.id] = {
    title: wi.fields['System.Title'],
    state: wi.fields['System.State'],
    type: wi.fields['System.WorkItemType']
  };
  if (wi.relations) {
    for (const rel of wi.relations) {
      if (rel.rel === 'ArtifactLink' && rel.attributes && rel.attributes.name === 'Pull Request') {
        const prId = parseInt(rel.url.split('/').pop(), 10);
        if (!isNaN(prId)) linkedPrIds.add(prId);
      }
    }
  }
}

console.log('Work items: ' + Object.keys(workItems).length);
console.log('Already linked PR IDs: ' + linkedPrIds.size);

fs.writeFileSync(p.join(home, 'ado-flow-tmp-wi-parsed.json'),
  JSON.stringify({ workItems, linkedPrIds: [...linkedPrIds] }));
```

```bash
node "$HOME/ado-flow-tmp-parse-wi.js"
```

---

## Phase 3: Fetch Sprint PRs (2 az calls)

**Run 3a and 3b in parallel.**

### 3a: Merged PRs (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests?searchCriteria.creatorId={USER_ID}&searchCriteria.status=completed&searchCriteria.minTime={SPRINT_START}T00:00:00Z&searchCriteria.queryTimeRangeType=closed&\$top=30&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-merged-prs.json"
```

### 3b: Active PRs (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests?searchCriteria.creatorId={USER_ID}&searchCriteria.status=active&searchCriteria.minTime={SPRINT_START}T00:00:00Z&\$top=20&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-active-prs.json"
```

Client-side: filter out `isDraft == true` from both.

---

## Phase 4: Match Unlinked PRs to Work Items (0 az calls)

Write a .js file to identify unlinked PRs and match them:

```javascript
// Write this to $HOME/ado-flow-tmp-match.js
const fs = require('fs'), p = require('path'), os = require('os');
const home = os.homedir();

function readJson(name) {
  try { return JSON.parse(fs.readFileSync(p.join(home, name), 'utf8')); }
  catch { return null; }
}

const wiData = readJson('ado-flow-tmp-wi-parsed.json');
const mergedPrs = readJson('ado-flow-tmp-merged-prs.json');
const activePrs = readJson('ado-flow-tmp-active-prs.json');

const linkedPrIds = new Set(wiData.linkedPrIds);
const wiIds = new Set(Object.keys(wiData.workItems).map(Number));

// Combine all PRs, filter out already-linked and drafts
const allPrs = [
  ...((mergedPrs?.value || []).filter(pr => !pr.isDraft)),
  ...((activePrs?.value || []).filter(pr => !pr.isDraft))
];

const unlinkedPrs = allPrs.filter(pr => !linkedPrIds.has(pr.pullRequestId));

if (unlinkedPrs.length === 0) {
  console.log(JSON.stringify({ unlinked: [], confident: [], fuzzy: [], noMatch: [] }));
  process.exit(0);
}

// --- Matching strategies (most to least reliable) ---

function extractIdsFromText(text) {
  if (!text) return [];
  const patterns = [
    /(?:AB)?#(\d{4,7})\b/g,     // #1234 or AB#1234
    /\bWI\s*(\d{4,7})\b/gi,     // WI 1234 or WI1234
    /\b(\d{4,7})\b/g            // bare numbers (only used in branch names)
  ];
  const ids = new Set();
  for (const pat of patterns) {
    let m;
    while ((m = pat.exec(text)) !== null) {
      const id = parseInt(m[1], 10);
      if (wiIds.has(id)) ids.add(id);
    }
  }
  return [...ids];
}

// Strategy 1: Branch name parsing
function matchByBranch(pr) {
  const branch = pr.sourceRefName?.replace('refs/heads/', '') || '';
  // Split by / and - to find numeric segments
  const segments = branch.split(/[\/\-_]/);
  for (const seg of segments) {
    const id = parseInt(seg, 10);
    if (!isNaN(id) && wiIds.has(id)) return { id, source: 'branch', branch };
  }
  // Also try regex on full branch name
  const ids = extractIdsFromText(branch);
  if (ids.length > 0) return { id: ids[0], source: 'branch', branch };
  return null;
}

// Strategy 2: PR title/description mentions
function matchByTitleDesc(pr) {
  const titleIds = extractIdsFromText(pr.title);
  if (titleIds.length > 0) return { id: titleIds[0], source: 'title' };
  const descIds = extractIdsFromText(pr.description);
  if (descIds.length > 0) return { id: descIds[0], source: 'description' };
  return null;
}

// Strategy 3: Fuzzy title matching (token overlap, threshold >= 0.3)
// Tokenizes both titles into words > 2 chars, computes overlap ratio.
// A score of 0.3 means at least 30% of significant words are shared.
// Below 0.3 = "No match". These are shown for individual confirmation.
function fuzzyMatch(prTitle) {
  const prWords = prTitle.toLowerCase().replace(/[^a-z0-9\s]/g, '').split(/\s+/).filter(w => w.length > 2);
  let bestMatch = null;
  let bestScore = 0;

  for (const [idStr, wi] of Object.entries(wiData.workItems)) {
    const wiWords = wi.title.toLowerCase().replace(/[^a-z0-9\s]/g, '').split(/\s+/).filter(w => w.length > 2);
    const common = prWords.filter(w => wiWords.includes(w)).length;
    const score = common / Math.max(prWords.length, wiWords.length);
    if (score > bestScore && score >= 0.3) {
      bestScore = score;
      bestMatch = { id: parseInt(idStr, 10), title: wi.title, score };
    }
  }
  return bestMatch;
}

const confident = [];
const fuzzy = [];
const noMatch = [];

for (const pr of unlinkedPrs) {
  const branchMatch = matchByBranch(pr);
  if (branchMatch) {
    confident.push({ pr, matchedWiId: branchMatch.id, source: branchMatch.source, detail: branchMatch.branch || '' });
    continue;
  }

  const titleMatch = matchByTitleDesc(pr);
  if (titleMatch) {
    confident.push({ pr, matchedWiId: titleMatch.id, source: titleMatch.source, detail: '' });
    continue;
  }

  const fuzzyResult = fuzzyMatch(pr.title);
  if (fuzzyResult) {
    fuzzy.push({ pr, matchedWiId: fuzzyResult.id, matchedTitle: fuzzyResult.title, score: fuzzyResult.score });
    continue;
  }

  noMatch.push({ pr });
}

console.log(JSON.stringify({ confident, fuzzy, noMatch }));
```

```bash
node "$HOME/ado-flow-tmp-match.js"
```

---

## Phase 5: Present Matches and Confirm (0 az calls)

Present the matches in this format:

> **Unlinked PRs in {MONTH_NAME} sprint:**
>
> **Confident matches (from branch/title):**
> 1. PR !{ID} "{TITLE}" (branch: {BRANCH}) -> #{WI_ID} {WI_TITLE}
> 2. PR !{ID} "{TITLE}" (title mentions #{WI_ID}) -> #{WI_ID} {WI_TITLE}
>
> **Fuzzy matches (title similarity):**
> 3. PR !{ID} "{TITLE}" -> likely #{WI_ID} ({WI_TITLE})?
>
> **No match found:**
> 4. PR !{ID} "{TITLE}"
>
> Link? **[a]**ll-confident **[1-6]** individually **[s]**kip-all

If there are no unlinked PRs:
> All PRs in the sprint are already linked. Nothing to do.

---

## Phase 6: Apply Links (N az calls)

**Requires permissions:** `vso.code_write` (to modify PRs) and `vso.work_write` (to create work item links). If the user's token lacks these scopes, the link calls will return 403.

**Rate-limit warning:** If more than 10 links will be applied, warn the user before proceeding: "About to create {N} links. Continue? (y/n)". This prevents unexpected bulk writes.

For each confirmed link, use `az repos pr work-item add`:

```bash
az repos pr work-item add \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --work-items {WI_ID} \
  --detect false 2>/dev/null
```

After each successful link, add a telemetry label to the PR (silent, fire-and-forget):

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/repositories/{REPO}/pullRequests/{PR_ID}/labels?api-version=7.1" \
  --headers "Content-Type=application/json" \
  --body '{"name":"adoflow-link-prs"}' \
  -o json 2>/dev/null || true
```

**One call per link.** Log results inline:

> PR !{PR_ID} -> #{WI_ID} linked
> PR !{PR_ID} -> #{WI_ID} FAILED: {error}

**Error handling:** Log inline, continue batch. Never abort.

---

## Phase 7: Summary + Cleanup

> Link-PRs done. {N} linked, {M} skipped, {J} no match.
> `{CALL_COUNT} API calls | {PR_COUNT} PRs checked | ~{ELAPSED}s`

```bash
rm -f "$HOME"/ado-flow-tmp-*.json "$HOME"/ado-flow-tmp-*.js 2>/dev/null
```

---

## Expected Call Counts

| Phase | First run | Cached run |
|-------|-----------|------------|
| Identity | 1 | 0 |
| Sprint detection | 0 | 0 |
| WIQL (sprint items) | 1 | 1 |
| Batch + Relations | 1 | 1 |
| Merged PRs | 1 | 1 |
| Active PRs | 1 | 1 |
| **Total (data)** | **6** | **5** |
| Linking | N | N |

**You MUST output the diagnostic line in the match presentation AND in the final summary.**

---

## Communication Style

- **Show matches first, ask second.** Present the full table, then ask for confirmation.
- **Confident = bulk linkable.** One prompt: "Link all {N} confident matches? [a]ll / [s]kip". User says "a" to link all at once.
- **Fuzzy = individual confirmation.** Each fuzzy match gets its own yes/no prompt: "Link PR !{ID} to #{WI_ID}? [y/n]".
- **No match = info only.** Show them but don't prompt for action.
- **Single-line results.** `PR !{ID} -> #{WI_ID} linked` — no filler.
- **Errors don't abort.** Log inline, continue, report at end.
- **Target: under 30 seconds for data collection, plus user confirmation time.**

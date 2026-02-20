---
name: adoflow:sprint-update
description: Auto-classify sprint work items using merged/open PRs, bulk-confirm updates, and flag blockers
argument-hint: "[update my sprint items | quick sprint update]"
---

# Azure DevOps Sprint Update

Auto-classifies work items by PR activity, bulk-confirms, walks through only ambiguous items.

## Arguments

<user_request> $ARGUMENTS </user_request>

**If empty, proceed with default workflow.**

---

## Hard Rules

1. **All data-fetching uses `az rest`.** Do not use `az boards query`, `az boards work-item show`, `az repos pr list`, or `az boards iteration *` for fetching. Only use `az boards work-item update` for writes.
2. **Always write az output to a file.** Pattern: `az rest ... -o json 2>/dev/null > "$HOME/ado-flow-tmp-{name}.json"`. Windows `az` CLI emits encoding warnings that corrupt inline JSON.
3. **Use `node -e` for JSON processing.** Never use `python3` or `python`. Never pipe into node via stdin. Always read from a file using `require('fs').readFileSync(path)`.
4. **Never use `/tmp/`.** It resolves to `C:\tmp\` in Node.js on Windows. Use `$HOME/ado-flow-tmp-*.json` for all temp files.
5. **Never run data-collection in the background.** All data must be collected before presenting the classification.
6. **Never loop through PRs to fetch linked work items.** The batch API `$expand=Relations` provides all PR links in one call.
7. **Do not fetch work item states separately.** Deduce state categories from the actual states on fetched work items. Use a broad static exclusion for the WIQL filter.
8. **Clean up temp files** at the end: `rm -f "$HOME"/ado-flow-tmp-*.json 2>/dev/null`

---

## Phase 0: Load Config (0 az calls)

```bash
cat "$HOME/.config/ado-flow/config.json" 2>/dev/null
```

If no config exists, follow the `ado-flow` skill for first-time setup.

**Accept both key formats:** `organization` or `ORG`, `work_item_project` or `WORK_ITEM_PROJECT`, `pr_project` or `PR_PROJECT`.

Map to: `{ORG}`, `{WI_PROJECT}`, `{PR_PROJECT}`.

Also check for cached keys: `user_id` (GUID), `user_email`, `sprint_cache`.

### Project Routing Rule

| API | Project |
|-----|---------|
| `_apis/wit/*` (WIQL, batch, work items) | `{WI_PROJECT}` |
| `_apis/git/pullrequests` | `{PR_PROJECT}` |
| `_apis/work/teamsettings/iterations` | `{WI_PROJECT}` |

**Never swap.** `{WI_PROJECT}` and `{PR_PROJECT}` may be different.

---

## Phase 1: Resolve User Identity (0-1 az calls, cached)

Check config for `user_id` (GUID) and `user_email`. **If both present, skip this phase.**

If missing, fetch via connection data (1 call):

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/_apis/connectionData?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-conn.json"
```

Extract from response:
- `authenticatedUser.id` → `{USER_ID}` (GUID, used for PR searchCriteria)
- `authenticatedUser.providerDisplayName` or look for email in properties → `{USER_EMAIL}`

If email not in connectionData, get it:
```bash
az account show --query "user.name" -o tsv 2>/dev/null
```

**Cache both immediately** in config using node:
```bash
node -e "
const fs=require('fs'), p=require('path'), os=require('os');
const f=p.join(os.homedir(),'.config','ado-flow','config.json');
const c=JSON.parse(fs.readFileSync(f,'utf8'));
c.user_id='{USER_ID}'; c.user_email='{USER_EMAIL}';
fs.writeFileSync(f,JSON.stringify(c,null,2));
"
```

---

## Phase 2: Fetch Work Items + Detect Sprint (2-3 az calls)

### 2a: Single WIQL Query (1 call)

One query does both iteration detection AND item fetching. Use a broad static exclusion that covers all ADO process templates:

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/wit/wiql?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --body '{"query": "SELECT [System.Id], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me AND [System.State] NOT IN ('"'"'Closed'"'"','"'"'Done'"'"','"'"'Resolved'"'"','"'"'Removed'"'"','"'"'Completed'"'"') ORDER BY [System.ChangedDate] DESC"}' \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-wiql.json"
```

**If the `--body` escaping is problematic**, write body to file first:

```bash
node -e "
const fs=require('fs'), p=require('path'), os=require('os');
fs.writeFileSync(p.join(os.homedir(),'ado-flow-tmp-wiql-body.json'),
  JSON.stringify({query: \"SELECT [System.Id], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me AND [System.State] NOT IN ('Closed','Done','Resolved','Removed','Completed') ORDER BY [System.ChangedDate] DESC\"}));
"
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/wit/wiql?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --body "@$HOME/ado-flow-tmp-wiql-body.json" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-wiql.json"
```

Parse with node:
- Response has `workItems[].id` and `columns` array. **Note:** WIQL via REST returns IDs only in `workItems`, field values are NOT inline. The `IterationPath` values come from a separate step.

Actually, the WIQL REST response only returns `workItems: [{id, url}]` — no field values. So we need the batch fetch to get IterationPath.

**Revised approach:** The WIQL gives us IDs. The batch fetch gives us fields (including IterationPath) + relations. From the batch results, we detect the sprint AND get all the data we need.

### 2b: Batch Fetch with Relations (1 call)

Write the request body:

```bash
node -e "
const fs=require('fs'), p=require('path'), os=require('os');
const wiql=JSON.parse(fs.readFileSync(p.join(os.homedir(),'ado-flow-tmp-wiql.json'),'utf8'));
const ids=wiql.workItems.map(w=>w.id);
console.log('Work items found: '+ids.length);
fs.writeFileSync(p.join(os.homedir(),'ado-flow-tmp-batch-body.json'),
  JSON.stringify({ids:ids,'\$expand':'Relations',fields:['System.Id','System.Title','System.State','System.WorkItemType','System.IterationPath','System.Tags','System.ChangedDate']}));
"
```

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/wit/workitemsbatch?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --body "@$HOME/ado-flow-tmp-batch-body.json" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-batch.json"
```

### 2c: Parse Everything from Batch Response

This single node script does iteration detection, sprint filtering, PR link extraction, and state deduction — all from the batch response:

```bash
node -e "
const fs=require('fs'), p=require('path'), os=require('os');
const data=JSON.parse(fs.readFileSync(p.join(os.homedir(),'ado-flow-tmp-batch.json'),'utf8'));

// 1. Detect sprint: most common non-backlog iteration
const iterCounts={};
for(const wi of data.value){
  const ip=wi.fields['System.IterationPath'];
  if(ip && ip.includes('\\\\') && !ip.toLowerCase().includes('backlog')) iterCounts[ip]=(iterCounts[ip]||0)+1;
}
const sprint=Object.entries(iterCounts).sort((a,b)=>b[1]-a[1])[0];
if(!sprint){console.log('NO_SPRINT'); process.exit(0);}
const sprintPath=sprint[0];
console.log('Sprint: '+sprintPath);

// 2. Filter to sprint items only
const sprintItems=data.value.filter(wi=>wi.fields['System.IterationPath']===sprintPath);
console.log('Sprint items: '+sprintItems.length);

// 3. Deduce states from actual items (no separate API call)
const states=new Set(sprintItems.map(wi=>wi.fields['System.State']));
console.log('States found: '+[...states].join(', '));

// 4. Extract PR links from relations
const wiPrMap={};
const workItems={};
for(const wi of sprintItems){
  workItems[wi.id]=wi.fields;
  wiPrMap[wi.id]=[];
  if(wi.relations){
    for(const rel of wi.relations){
      if(rel.rel==='ArtifactLink' && rel.attributes && rel.attributes.name==='Pull Request'){
        const prId=parseInt(rel.url.split('/').pop(),10);
        if(!isNaN(prId)) wiPrMap[wi.id].push(prId);
      }
    }
  }
}
const allPrIds=[...new Set(Object.values(wiPrMap).flat())];
console.log('PR links: '+allPrIds.length+' unique');

// 5. Save parsed data
fs.writeFileSync(p.join(os.homedir(),'ado-flow-tmp-parsed.json'),JSON.stringify({sprintPath,workItems,wiPrMap,allPrIds,states:[...states]}));
"
```

If `NO_SPRINT`, ask the user for their iteration path.

### 2d: Sprint Dates (0-1 calls, cached)

Check `sprint_cache` in config. **If valid (today ≤ end_date), skip.**

If stale or missing (1 call):

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/work/teamsettings/iterations?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-iterations.json"
```

Parse with node to find matching iteration by path, extract `attributes.startDate` and `attributes.finishDate`. If not found in team settings, fall back to:

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{WI_PROJECT}/_apis/wit/classificationnodes/Iterations?api-version=7.1&\$depth=5" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-class-iterations.json"
```

Parse recursively to find matching node. Cache sprint dates immediately.

---

## Phase 3: Fetch Sprint-Scoped PRs via REST (2 calls, run in parallel)

**Use `az rest` with `searchCriteria.minTime` for server-side date filtering.** This returns only PRs within the sprint window — no client-side date filtering needed.

### 3a: Merged PRs (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests?searchCriteria.creatorId={USER_ID}&searchCriteria.status=completed&searchCriteria.minTime={SPRINT_START}T00:00:00Z&searchCriteria.queryTimeRangeType=closed&\$top=30&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-merged-prs.json"
```

**Validate:** If 0 results and this is the first run, the `{PR_PROJECT}` may be wrong. Warn: "No PRs found in `{PR_PROJECT}`. Is this the correct project for your repos?" Ask the user and update config if needed.

Client-side: filter out `isDraft == true` (unlikely for completed PRs, but safe).

### 3b: Active Non-Draft PRs (1 call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests?searchCriteria.creatorId={USER_ID}&searchCriteria.status=active&searchCriteria.minTime={SPRINT_START}T00:00:00Z&\$top=20&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-active-prs.json"
```

Client-side: filter out `isDraft == true`.

### 3c: Cross-Reference + Reviewers (0 calls + 0-3 calls)

Parse merged and active PRs. Build lookups: `{MERGED_PR_MAP}`, `{ACTIVE_PR_MAP}`.

Cross-reference with `{WI_PR_MAP}` from Phase 2c — all in-memory, 0 calls.

**Note:** The PR list response already includes `reviewers[]` with vote status. Check if reviewer data is present — if so, skip separate reviewer calls entirely. The `reviewers` field on each PR contains `vote` values (10=approved, 0=no vote, -5=wait, -10=reject).

If reviewers are NOT in the list response, fetch only for linked active PRs:

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/pullrequests/{PR_ID}?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null
```

### 3d: Unlinked PR Detection (0 calls)

From merged + active PR maps, identify PRs not in `{WI_PR_MAP}`. Fuzzy match titles against work items. Present as suggestions.

---

## Phase 4: Classify and Present (0 az calls)

### State Classification

Deduce categories from actual states on fetched items — no external lookup:

| Common states | Category |
|--------------|----------|
| New, To Do, Proposed | NOT_STARTED |
| Active, In Progress, Committed, Open | IN_PROGRESS |

If an item's state doesn't match known patterns, treat it as IN_PROGRESS.

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

- Skip items already in a done state (shouldn't be in results, but check).
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

**Use `az boards work-item update` for writes** (simpler than REST PATCH):

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{TARGET_STATE}" \
  --discussion "Sprint update: {REASON}" \
  -o json 2>/dev/null
```

**State transition safety:** If the update fails with a state transition error, try going through an intermediate state first. Deduce the intermediate from the item's current state and target.

**Sanitizing `--discussion`:** Strip double quotes and backticks.

**Error handling:** Log inline (`#{ID} — FAILED: {msg}`), continue batch. Never abort.

### Items Needing Input

Present all together after auto-apply:

> Items needing input:
> 1. `#{ID}` {TITLE} — stale / carryover / changes requested
> 2. PR !{PR_ID} "{TITLE}" — unlinked, likely match: `#{WI_ID}`
>
> Actions: **r**esolve **b**:"reason" **x**remove **s**kip **y**link
> Enter (e.g., `1s 2b:"waiting on API team" 3y`):

Execute actions using `az boards work-item update` or `az repos pr work-item add`.

---

## Phase 6: Summary + Cleanup

> Sprint update done. {N} resolved, {M} commented, {J} skipped.
> {CALL_COUNT} API calls | {WORK_ITEM_COUNT} items | ~{ELAPSED}s

```bash
rm -f "$HOME"/ado-flow-tmp-*.json 2>/dev/null
```

---

## Expected Call Counts

| Phase | First run | Cached run |
|-------|-----------|------------|
| Identity | 1 | 0 |
| WIQL + Batch | 2 | 2 |
| Sprint dates | 1 | 0 |
| Merged PRs | 1 | 1 |
| Active PRs | 1 | 1 |
| Reviewers | 0-3 | 0-3 |
| **Total (data)** | **6-9** | **4-7** |
| Updates (apply) | N | N |

**You MUST output the diagnostic line in the classification AND in the final summary.**

---

## Communication Style

- **Auto-classify first, ask second.** Developer confirms a plan, not builds one.
- **Bulk confirmation default.** Only surface items needing human judgment.
- **Single-line confirmations.** `#{ID} -> Resolved` — no filler.
- **Target: under 60 seconds, max 3 developer inputs.**
- **Errors don't abort.** Log inline, continue, report at end.

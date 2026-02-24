---
name: adoflow-build-analyzer
description: Analyze why the latest build failed — compares failed vs passed builds, identifies the broken step, fetches logs, and summarizes root cause
argument-hint: "[pipeline-name]"
---

# Azure DevOps Build Analyzer

Automatically analyze a failed pipeline build by comparing it to the last successful build on the same branch. Identifies the failed step, fetches logs from both builds, and summarizes the likely root cause.

## Arguments

$ARGUMENTS

**If the request above is empty, ask the user:** "Which pipeline should I analyze? Provide the pipeline name (e.g., `my-app-ci`)."

Do not proceed until you have a pipeline name.

---

## Hard Rules

1. **All data-fetching uses `az rest`.** Do not use `az boards query`, `az boards work-item show`, `az repos pr list`, `az pipelines *`, or `az boards iteration *` for fetching.
2. **Always write az output to a file.** Pattern: `az rest ... -o json 2>/dev/null > "$HOME/ado-flow-tmp-{name}.json"`. Windows `az` CLI emits encoding warnings that corrupt inline JSON.
3. **For scripts longer than 3 lines, write to a .js file** and run with `node "$HOME/ado-flow-tmp-{name}.js"`. Do not use `node -e` for complex scripts — backslash escaping breaks on Windows. For 1-3 line scripts, `node -e` is fine.
4. **Never use `python3` or `python`.** Never pipe into node via stdin. Always read from files.
5. **Never use `/tmp/`.** It resolves to `C:\tmp\` in Node.js on Windows. Use `$HOME/ado-flow-tmp-*` for all temp files.
6. **Never run data-collection in the background.** All data must be collected before presenting results.
7. **connectionData API requires `api-version=7.1-preview`** (not `7.1`).
8. **Clean up temp files** at the end: `rm -f "$HOME"/ado-flow-tmp-*.json "$HOME"/ado-flow-tmp-*.js 2>/dev/null`
9. **This command is read-only.** No writes to Azure DevOps.
10. **After each `az rest` call writing to a file, verify the file is non-empty.** If 0 bytes, re-run without `2>/dev/null` to diagnose.
11. **All `az rest` calls must include `--resource "499b84ac-1321-427f-aa17-267ca6975798"`.** This is the Azure DevOps resource ID for authentication.

---

## Phase 0: Load Config (0 az calls)

```bash
cat "$HOME/.config/ado-flow/config.json" 2>/dev/null
```

If no config exists, follow the `ado-flow` skill for first-time setup.

**Accept both key formats:** `organization` or `ORG`, `work_item_project` or `WORK_ITEM_PROJECT`, `pr_project` or `PR_PROJECT`.

Map to: `{ORG}`, `{WI_PROJECT}`, `{PR_PROJECT}`.

**Project for this command:** `{PROJECT}` uses `{WI_PROJECT}` from config.

The user may override org or project via arguments (e.g., `my-pipeline org=myorg project=MyProject`). Parse any `key=value` pairs from `$ARGUMENTS` and apply them.

Store the pipeline name from `$ARGUMENTS` as `{PIPELINE_NAME}`.

---

## Phase 1: Resolve Pipeline ID (1 az call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PROJECT}/_apis/build/definitions?name={PIPELINE_NAME}&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-ba-defs.json"
```

Parse the response:

```javascript
node -e "const d=JSON.parse(require('fs').readFileSync(process.env.HOME+'/ado-flow-tmp-ba-defs.json','utf8'));console.log(d.count,d.value?.[0]?.id??'')"
```

- If `count` is 0: respond with **"No pipeline found with name '{PIPELINE_NAME}'. Check the spelling."** and stop.
- Otherwise extract `{PIPELINE_ID}` from `value[0].id`.

---

## Phase 2: Get Default Branch (1 az call)

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PROJECT}/_apis/build/definitions/{PIPELINE_ID}?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-ba-def.json"
```

Extract `{DEFAULT_BRANCH}` from `repository.defaultBranch`.

---

## Phase 3: Get Latest Failed and Passed Builds (2 az calls — run in parallel)

**Latest failed build:**

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PROJECT}/_apis/build/builds?definitions={PIPELINE_ID}&branchName={DEFAULT_BRANCH}&resultFilter=failed,canceled&\$top=1&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-ba-failed.json"
```

**Latest passed build:**

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PROJECT}/_apis/build/builds?definitions={PIPELINE_ID}&branchName={DEFAULT_BRANCH}&resultFilter=succeeded,partiallySucceeded&\$top=1&api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-ba-passed.json"
```

Extract `{FAILED_BUILD_ID}` and `{PASSED_BUILD_ID}` from `value[0].id` in each response. Also extract `buildNumber`, `finishTime`, and `result` for the summary.

**Error handling:**
- If no failed builds found (`count` is 0): respond with **"No failed or canceled builds found on {DEFAULT_BRANCH}. The pipeline is healthy."** and stop.
- If no passed builds found (`count` is 0): note this and continue — we will show the failed log only in Phase 7.

---

## Phase 4: Get Timelines for Both Builds (1-2 az calls — run in parallel)

**Failed build timeline:**

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PROJECT}/_apis/build/builds/{FAILED_BUILD_ID}/timeline?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-ba-tl-failed.json"
```

**Passed build timeline** (skip if no passed build):

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PROJECT}/_apis/build/builds/{PASSED_BUILD_ID}/timeline?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  -o json 2>/dev/null > "$HOME/ado-flow-tmp-ba-tl-passed.json"
```

---

## Phase 5: Identify Failed Steps (node script)

Write a script to `$HOME/ado-flow-tmp-ba-failed-steps.js`:

```javascript
const fs = require('fs');
const tl = JSON.parse(fs.readFileSync(process.env.HOME + '/ado-flow-tmp-ba-tl-failed.json', 'utf8'));

const failedSteps = tl.records.filter(r => r.result === 'failed' && r.type === 'Task');

if (failedSteps.length === 0) {
  console.log(JSON.stringify({ error: 'no_failed_tasks', records: [] }));
} else {
  const steps = failedSteps.map(s => ({
    name: s.name,
    id: s.id,
    logId: s.log ? s.log.id : null,
    result: s.result,
    issues: s.issues || []
  }));
  console.log(JSON.stringify({ error: null, records: steps }));
}
```

```bash
node "$HOME/ado-flow-tmp-ba-failed-steps.js"
```

If no failed tasks are found, check for records with `result === 'failed'` of any type (not just `Task`). Report what was found and stop if nothing is actionable.

Store the list of failed steps, particularly the first one as `{FAILED_STEP}`.

---

## Phase 6: Find Matching Step in Passed Build (node script)

Skip this phase if there is no passed build.

Write a script to `$HOME/ado-flow-tmp-ba-match-step.js`:

```javascript
const fs = require('fs');
const failedStepName = process.argv[2];
const tl = JSON.parse(fs.readFileSync(process.env.HOME + '/ado-flow-tmp-ba-tl-passed.json', 'utf8'));

const match = tl.records.find(r => r.name === failedStepName && r.type === 'Task');

if (!match) {
  console.log(JSON.stringify({ found: false }));
} else {
  console.log(JSON.stringify({
    found: true,
    name: match.name,
    id: match.id,
    logId: match.log ? match.log.id : null,
    result: match.result
  }));
}
```

```bash
node "$HOME/ado-flow-tmp-ba-match-step.js" "{FAILED_STEP_NAME}"
```

- If `found` is false: note **"Step '{FAILED_STEP_NAME}' not found in the passed build. Showing failed step log only."** and continue without the passed log.
- Otherwise store `{PASSED_STEP_LOG_ID}`.

---

## Phase 7: Fetch Logs (1-2 az calls — run in parallel)

**Failed step log:**

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PROJECT}/_apis/build/builds/{FAILED_BUILD_ID}/logs/{FAILED_STEP_LOG_ID}?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --output-file "$HOME/ado-flow-tmp-ba-log-failed.txt"
```

**Passed step log** (skip if no passed build or no matching step):

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PROJECT}/_apis/build/builds/{PASSED_BUILD_ID}/logs/{PASSED_STEP_LOG_ID}?api-version=7.1" \
  --resource "499b84ac-1321-427f-aa17-267ca6975798" \
  --output-file "$HOME/ado-flow-tmp-ba-log-passed.txt"
```

**Note:** Build log endpoints return plain text, not JSON. Use `--output-file` instead of stdout redirect — the `az rest` stdout path hits `charmap` encoding errors on Windows when logs contain unicode characters.

If the logs are very large (>500 lines), focus on the last 200 lines of the failed log where errors typically appear, and use the passed log for context comparison.

---

## Phase 8: Analyze and Summarize

Read both log files and produce a root cause analysis. Present the results in the following format:

---

### Build Analysis: {PIPELINE_NAME}

**Branch:** `{DEFAULT_BRANCH}`

| | Failed Build | Passed Build |
|---|---|---|
| **Build #** | {FAILED_BUILD_NUMBER} | {PASSED_BUILD_NUMBER} |
| **Result** | {FAILED_RESULT} | {PASSED_RESULT} |
| **Finished** | {FAILED_FINISH_TIME} | {PASSED_FINISH_TIME} |

**Failed Step:** `{FAILED_STEP_NAME}`

**Error Summary:**
> [Extract the key error message from the failed log — look for lines with "error", "Error", "FAILED", "##[error]", or exception messages]

**What Changed:**
> [Compare the failed and passed logs for the same step. Highlight specific differences — e.g., different package versions, different test failures, environment changes, timeout differences]

**Likely Root Cause:**
> [Based on the error and diff, provide a concise assessment of what likely caused the failure — e.g., "A transient NuGet restore timeout", "New test failure in XYZ.Tests.SomeTest", "Package version conflict for Foo.Bar 2.3.1"]

**Suggested Next Steps:**
> [1-3 actionable suggestions — e.g., "Re-run the build to check if it's transient", "Investigate the failing test", "Check if package Foo.Bar 2.3.1 was recently updated"]

---

If there is no passed build for comparison, omit the "What Changed" section and note that no successful build was available for comparison.

If multiple steps failed, analyze the **first** failed step in detail and list the other failed steps as additional failures.

---

## Phase 9: Clean Up

```bash
rm -f "$HOME"/ado-flow-tmp-ba-*.json "$HOME"/ado-flow-tmp-ba-*.js "$HOME"/ado-flow-tmp-ba-*.txt 2>/dev/null
```

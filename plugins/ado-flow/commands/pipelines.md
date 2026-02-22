---
name: adoflow:pipelines
description: Run, list, monitor, and manage Azure DevOps pipelines and builds using natural language
argument-hint: "[list pipelines | run Build-CI | show build #567 | cancel build #567 | show runs for Build-CI]"
---

# Azure DevOps Pipelines

Manage pipelines and builds in Azure DevOps: list, run, monitor, cancel, and view artifacts.

## Arguments

$ARGUMENTS

**If the request above is empty, ask the user:** "What would you like to do with pipelines? For example: list pipelines, run a pipeline, check a build status, or view recent runs."

Do not proceed until you have a clear request from the user.

## Prerequisites

Before doing anything, load the shared configuration by following the setup instructions in the `ado-flow` skill's "First-Time Setup" section.

Load the config:

```bash
cat "$HOME/.config/ado-flow/config.json" 2>/dev/null
```

If no config exists, follow the `ado-flow` skill to run first-time setup. Once config is loaded, you will have: `{ORG}`, `{WORK_ITEM_PROJECT}` (used as the default project for pipelines).

---

## Workflows

### List Pipelines

When the user asks to see their pipelines:

```bash
az pipelines list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  -o json
```

Present in a clean table:

> Here are the pipelines in your project:
> | ID | Name | Folder |
> |----|------|--------|
> | 1 | Build-CI | \\ |
> | 2 | Deploy-Staging | \\deploy |

---

### Run a Pipeline

When the user asks to run or trigger a pipeline:

1. If no pipeline specified, list pipelines and ask which one to run.

2. **Optionally ask for branch** - default to the main branch:

> Which branch should I run this on? (Default: main)

3. **Optionally ask for parameters** if the pipeline accepts them.

4. **Run the pipeline:**

```bash
az pipelines run \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --name "{PIPELINE_NAME}" \
  --branch "{BRANCH}" \
  -o json
```

Or by pipeline ID:

```bash
az pipelines run \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --id {PIPELINE_ID} \
  --branch "{BRANCH}" \
  -o json
```

To pass parameters:

```bash
az pipelines run \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --name "{PIPELINE_NAME}" \
  --parameters "key1=value1" "key2=value2" \
  -o json
```

5. **Add a telemetry tag to the build** (silent, fire-and-forget — do not report errors to the user):

```bash
az pipelines build tag add \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --build-id {BUILD_ID} \
  --tags "adoflow:pipelines" \
  -o json 2>/dev/null || true
```

6. **Confirm:** "Pipeline '{PIPELINE_NAME}' has been triggered on branch '{BRANCH}'. Build ID: #{BUILD_ID}."

---

### Show Pipeline Details

When the user asks about a specific pipeline:

```bash
az pipelines show \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --name "{PIPELINE_NAME}" \
  -o json
```

Or by ID:

```bash
az pipelines show \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --id {PIPELINE_ID} \
  -o json
```

Present: pipeline name, folder, default branch, and YAML file path.

---

### List Recent Builds

When the user asks for recent builds or build history:

```bash
az pipelines build list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --top 10 \
  -o json
```

To filter by a specific pipeline:

```bash
az pipelines build list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --definition-ids {PIPELINE_ID} \
  --top 10 \
  -o json
```

Present in a clean table:

> Recent builds:
> | Build ID | Pipeline | Branch | Status | Result | Started |
> |----------|----------|--------|--------|--------|---------|
> | 567 | Build-CI | main | completed | succeeded | 2 hours ago |
> | 566 | Build-CI | feature/x | completed | failed | 5 hours ago |

---

### Show Build Details

When the user asks about a specific build:

```bash
az pipelines build show \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --id {BUILD_ID} \
  -o json
```

Present key information: build number, pipeline name, status, result, source branch, start/finish times, requested by, and reason (manual, CI, PR, etc.).

If the build failed, highlight the result and suggest viewing the build logs in the browser.

---

### Cancel a Build

When the user asks to cancel a running build:

**Confirm first:** "Are you sure you want to cancel build #{BUILD_ID}?"

```bash
az pipelines build cancel \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --build-id {BUILD_ID} \
  -o json
```

Confirm: "Build #{BUILD_ID} has been cancelled."

---

### List Pipeline Runs

When the user asks for runs of a specific pipeline:

```bash
az pipelines runs list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --pipeline-ids {PIPELINE_ID} \
  --top 10 \
  -o json
```

Present in a clean table with run ID, status, result, branch, and time.

---

### Show Run Details

When the user asks about a specific pipeline run:

```bash
az pipelines runs show \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --id {RUN_ID} \
  -o json
```

Present: run ID, pipeline name, state, result, source branch, created date, and finish date.

---

### List Run Artifacts

When the user asks what artifacts a run produced:

```bash
az pipelines runs artifact list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --run-id {RUN_ID} \
  -o json
```

Present artifact names and types in a simple list.

---

### Download a Run Artifact

When the user wants to download an artifact:

```bash
az pipelines runs artifact download \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --run-id {RUN_ID} \
  --artifact-name "{ARTIFACT_NAME}" \
  --path "{DOWNLOAD_PATH}" \
  -o json
```

Ask for the download path if not specified. Default to the current directory.

Confirm: "Artifact '{ARTIFACT_NAME}' has been downloaded to {DOWNLOAD_PATH}."

---

### Manage Build Tags

**List tags on a build:**

```bash
az pipelines build tag list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --build-id {BUILD_ID} \
  -o json
```

**Add a tag:**

```bash
az pipelines build tag add \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --build-id {BUILD_ID} \
  --tags "{TAG}" \
  -o json
```

**Delete a tag:**

```bash
az pipelines build tag delete \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --build-id {BUILD_ID} \
  --tag "{TAG}" \
  -o json
```

---

### List Pipeline Variables

When the user wants to see variables configured on a pipeline:

```bash
az pipelines variable list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --pipeline-name "{PIPELINE_NAME}" \
  -o json
```

Present variable names and values (mark secrets as `***`).

# Azure DevOps CLI Command Reference

This reference documents the `az boards` and `az repos` CLI commands used by the azure-devops skill.

## Common Flags

All commands require these flags (provided from saved config):

```
--org https://dev.azure.com/{ORGANIZATION}
--project {PROJECT_NAME}
```

---

## Work Items

### Create a Work Item

```bash
az boards work-item create \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --type "{WORK_ITEM_TYPE}" \
  --title "Title here" \
  --area "{AREA_PATH}" \
  --iteration "{ITERATION_PATH}" \
  --assigned-to "{USER_EMAIL}" \
  --description "Description here" \
  -o json
```

Optional fields (use `--fields` for additional fields):

```bash
--fields "Microsoft.VSTS.Common.Priority=2" "Microsoft.VSTS.Common.Severity=2 - High"
```

### List Available Work Item Types

```bash
az boards work-item type list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --query "[].{Name:name}" \
  -o table
```

### Query Work Items (WIQL)

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --wiql "SELECT [System.Id], [System.Title], [System.State], [System.AssignedTo], [System.AreaPath], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me AND [System.State] <> 'Closed' ORDER BY [System.ChangedDate] DESC" \
  -o json
```

### Get a Work Item by ID

```bash
az boards work-item show \
  --org "https://dev.azure.com/{ORG}" \
  --id {WORK_ITEM_ID} \
  -o json
```

### Update a Work Item

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {WORK_ITEM_ID} \
  --state "Active" \
  --assigned-to "user@example.com" \
  -o json
```

### List Recent Work Items Assigned to Me

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --wiql "SELECT [System.Id], [System.Title], [System.State], [System.AreaPath], [System.IterationPath], [System.WorkItemType] FROM workitems WHERE [System.AssignedTo] = @me ORDER BY [System.ChangedDate] DESC" \
  -o json
```

---

## Pull Requests

### Create a Pull Request

```bash
az repos pr create \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --repository "{REPO_NAME}" \
  --source-branch "{SOURCE_BRANCH}" \
  --target-branch "{TARGET_BRANCH}" \
  --title "PR Title" \
  --description "PR Description" \
  --auto-complete false \
  -o json
```

### List My Pull Requests

```bash
az repos pr list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --creator "@me" \
  --status active \
  -o json
```

### Get a Pull Request by ID

```bash
az repos pr show \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

### List PR Comments (Threads) via REST API

The `az repos pr thread` subcommand is not available in all versions of the Azure DevOps CLI extension. Use the REST API instead:

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PROJECT}/_apis/git/repositories/{REPO}/pullRequests/{PR_ID}/threads?api-version=7.1" \
  --resource "https://management.core.windows.net/" \
  --output-file /tmp/pr_threads.json
```

Then read and parse the JSON file. Active threads have `"status": "active"`.

**Windows note:** If the `az rest` command fails with encoding errors, the `--output-file` flag avoids the issue by writing directly to a file instead of stdout.

### List PR Reviewers

```bash
az repos pr reviewer list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

### Set PR to Auto-Complete

```bash
az repos pr update \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --auto-complete true \
  -o json
```

### List PR Policies/Checks

```bash
az repos pr policy list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

---

## Repositories

### List Repositories

```bash
az repos list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  -o json
```

---

## Detecting Area Path and Iteration Path

Area path and iteration path are detected dynamically from the user's recent work items rather than being hardcoded or saved in config.

### Query to Fetch Recent Patterns

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PROJECT}" \
  --wiql "SELECT [System.Id], [System.Title], [System.AreaPath], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me ORDER BY [System.ChangedDate] DESC" \
  -o json
```

### Area Path Detection

Count occurrences of each `System.AreaPath` across the last 10 results. The most common value is the default.

### Iteration Path Detection

From the last 10 results, collect `System.IterationPath` values. Filter out:
- Values that are just the project name (a single segment with no backslash separator)
- Values containing `Backlog`

The most common remaining iteration path (from recent items) is the default for new work items.

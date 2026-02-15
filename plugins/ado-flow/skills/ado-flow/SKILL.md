---
name: ado-flow
description: This skill should be used when working with Azure DevOps work items and pull requests. It applies when creating, querying, or updating work items, creating or reviewing pull requests, checking PR comments, or listing reviewers. Triggers on requests like "create a bug", "create a task", "show my PRs", "create a PR", "show PR comments", "list my work items", or any Azure DevOps-related operations. Designed for non-technical users with guided setup and persistent configuration.
---

# Azure DevOps - Shared Setup & Configuration

This is the shared foundation for all `adoflow:*` commands. It handles first-time setup, configuration persistence, and common detection logic.

## First-Time Setup

On every invocation of any `adoflow:*` command, check whether saved configuration exists before doing anything else.

### Step 1: Load Saved Configuration

Check for the config file at `~/.config/ado-flow/config.json`.

```bash
cat ~/.config/ado-flow/config.json 2>/dev/null
```

If the file exists and contains valid JSON with all required fields (`organization`, `work_item_project`, `pr_project`), skip ahead to the relevant task workflow. No setup is needed.

If the file does not exist or is missing fields, proceed with setup steps below.

### Step 2: Check Prerequisites

Verify Azure CLI and the DevOps extension are installed:

```bash
az version 2>/dev/null && az extension show --name azure-devops 2>/dev/null && az account show --query "user.name" -o tsv 2>/dev/null
```

If Azure CLI is missing, display:

> Azure CLI is not installed. Install it:
> - **Windows:** `winget install Microsoft.AzureCLI`
> - **macOS:** `brew install azure-cli`
> - **Linux:** `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`

If the Azure DevOps extension is missing, display:

> The Azure DevOps extension is not installed. To install it, run:
> `az extension add --name azure-devops`
> Let me know once that is done.

If the user is not logged in, display:

> Please log in to Azure CLI first by running: `az login`

### Step 3: Collect Configuration

Once prerequisites pass, ask the user for these details one at a time in a conversational manner:

1. **Organization name** - "What is your Azure DevOps organization name? (This is the part after `dev.azure.com/` in your URL)"
2. **Project for work items** - "What project should I create work items in?"
3. **Project for pull requests** - "What project are your repositories in? (Same as above, or different?)"

If the user says "same" for the PR project, use the same value as the work item project.

### Step 4: Save Configuration

Save all collected values to the config file:

```bash
mkdir -p ~/.config/ado-flow
cat > ~/.config/ado-flow/config.json <<EOF
{
  "organization": "{ORG}",
  "work_item_project": "{WORK_ITEM_PROJECT}",
  "pr_project": "{PR_PROJECT}"
}
EOF
```

Confirm to the user:

> All set! Your configuration has been saved. You will not need to provide these details again.
> When creating work items, I will automatically detect the right area path and iteration path from your recent work.

---

## Detecting Area Path and Iteration Path from Recent Work Items

Area path and iteration path are **not saved in config**. Instead, detect them dynamically each time a work item is created by fetching the user's last 10 work items:

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id], [System.Title], [System.AreaPath], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me ORDER BY [System.ChangedDate] DESC" \
  -o json
```

### Identifying the Area Path

From the returned work items, count occurrences of each distinct `System.AreaPath` value. The most frequently used area path across the last 10 items is the default. Present it to the user for confirmation:

> Based on your recent work items, I'll use this area path: `{DETECTED_AREA_PATH}`
> Is that correct? (You can specify a different one if needed.)

### Identifying the Iteration Path

From the same returned work items, examine the `System.IterationPath` values. To find the correct current iteration:

1. Collect all distinct iteration path values, excluding any that are just the project root (a single segment with no backslash) or contain `Backlog`
2. Identify the most recent/common non-backlog iteration path
3. Use that as the default iteration path

Present it to the user for confirmation:

> For the iteration path, your recent work items use: `{DETECTED_ITERATION_PATH}`
> Should I use this, or a different one?

If no clear pattern is found (e.g., all items are in Backlog or the project root), ask the user to provide the iteration path manually.

---

## Detecting Available Work Item Types

Work item types vary by project and process template (Agile, Scrum, CMMI, Basic). Do not assume which types are available. Instead, detect them:

```bash
az boards work-item type list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --query "[].{Name:name}" \
  -o table
```

Common types across templates:
- **Agile**: Bug, User Story, Task, Feature, Epic
- **Scrum**: Bug, Product Backlog Item, Task, Feature, Epic
- **CMMI**: Bug, Requirement, Task, Feature, Epic
- **Basic**: Issue, Task, Epic

When the user asks to create a work item without specifying a type, present the available types detected from their project.

---

## Communication Style

This skill is designed for non-technical users. When interacting:

- Use plain, simple language. Avoid jargon.
- Present results in clean tables or numbered lists.
- When something fails, explain what went wrong and what to do next in clear steps.
- Never show raw JSON to the user. Always parse and format the output.
- When asking for input, provide examples of what a valid answer looks like.
- Confirm successful actions with a brief summary.

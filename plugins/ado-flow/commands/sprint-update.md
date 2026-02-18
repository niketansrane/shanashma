---
name: adoflow:sprint-update
description: Check active work items in the current sprint and cross-reference with merged PRs to generate a status update
argument-hint: "[show my sprint updates | what's the status of my sprint items | sprint progress report]"
---

# Azure DevOps Sprint Update

Generate a sprint status update by cross-referencing active work items in the current sprint with merged pull requests — even if the PRs are in a different project.

## Arguments

<user_request> #$ARGUMENTS </user_request>

**If the request above is empty, proceed with the default workflow:** generate a sprint update for the current user's active work items and their related merged PRs.

## Prerequisites

Before doing anything, load the shared configuration by following the setup instructions in the `ado-flow` skill's "First-Time Setup" section.

Load the config:

```bash
cat ~/.config/ado-flow/config.json 2>/dev/null
```

If no config exists, follow the `ado-flow` skill to run first-time setup. Once config is loaded, you will have: `{ORG}`, `{WORK_ITEM_PROJECT}`, `{PR_PROJECT}`.

---

## Workflow

### Step 1: Detect the Current Sprint Iteration Path

Fetch the user's recent work items to determine the current sprint iteration path, following the "Detecting Area Path and Iteration Path from Recent Work Items" section in the shared skill.

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me ORDER BY [System.ChangedDate] DESC" \
  -o json
```

From the results, identify the current sprint iteration path (the most recent non-backlog, non-root iteration path). Use this as `{CURRENT_ITERATION}`.

If no clear iteration is found, ask the user:

> "I couldn't detect your current sprint. Could you tell me the iteration path? (e.g., `MyProject\\Sprint 5`)"

---

### Step 2: Fetch Active Work Items in the Current Sprint

Query all active (non-closed, non-removed) work items assigned to the user in the current sprint:

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me AND [System.IterationPath] = '{CURRENT_ITERATION}' AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' ORDER BY [System.WorkItemType] ASC, [System.State] ASC" \
  -o json
```

Present a summary table:

> Here are your active work items in **{CURRENT_ITERATION}**:
> | ID | Type | Title | State |
> |----|------|-------|-------|
> | 1234 | Bug | Fix login crash | Active |
> | 1235 | Task | Add unit tests | New |

If no active work items are found, inform the user:

> "You have no active work items in the current sprint ({CURRENT_ITERATION}). Would you like to check a different iteration?"

---

### Step 3: Fetch Merged PRs for the User

Fetch recently completed (merged) PRs created by the user. Since PRs may be in a different project than work items, query the PR project:

```bash
az repos pr list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --creator "@me" \
  --status completed \
  --top 50 \
  -o json
```

From the results, collect all merged PRs. For each PR, extract:
- PR ID
- Title
- Repository name
- Source branch
- Target branch
- Completion date (closedDate)

Filter to PRs merged during the likely timeframe of the current sprint (look at the iteration path name for sprint dates, or use the last 30 days as a reasonable window).

---

### Step 4: Fetch Linked Work Items for Each PR

For each merged PR, check which work items are linked to it:

```bash
az repos pr work-item list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

Build a mapping of **work item ID → list of merged PRs**.

---

### Step 5: Cross-Reference and Generate the Update

For each active work item from Step 2, look up whether any merged PRs from Step 4 are linked to it.

Present the sprint update report:

> ## Sprint Update — {CURRENT_ITERATION}
>
> ### Work Items with Merged PRs
>
> **#{WORK_ITEM_ID} - {TITLE}** ({STATE})
> - PR #{PR_ID}: "{PR_TITLE}" merged into `{TARGET_BRANCH}` in `{REPO}` on {DATE}
> - PR #{PR_ID2}: "{PR_TITLE2}" merged into `{TARGET_BRANCH}` in `{REPO}` on {DATE}
>
> ### Work Items with No Merged PRs Yet
>
> **#{WORK_ITEM_ID} - {TITLE}** ({STATE})
> - No merged PRs found linked to this item.

---

### Step 6: Check for Unlinked PRs

After the main report, check if any merged PRs from Step 3 were **not linked to any active sprint work item**. If so, mention them:

> ### Merged PRs Not Linked to Sprint Work Items
>
> These PRs were merged recently but are not linked to any active work item in the current sprint:
> - PR #{PR_ID}: "{PR_TITLE}" in `{REPO}` — merged {DATE}
>
> Would you like to link any of these to a work item?

---

## Handling Cross-Project PRs

If `{WORK_ITEM_PROJECT}` and `{PR_PROJECT}` are different in the config, the command automatically handles this:
- Work items are queried from `{WORK_ITEM_PROJECT}`
- PRs are queried from `{PR_PROJECT}`
- The link between them is resolved via the PR's linked work items (which can reference work items in any project within the organization)

If the user mentions PRs are in a third project not in the config, ask:

> "Which project are those PRs in? I'll check there too."

Then query that project additionally:

```bash
az repos pr list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{OTHER_PROJECT}" \
  --creator "@me" \
  --status completed \
  --top 50 \
  -o json
```

Merge the results with the existing PR list and continue the cross-referencing.

---

## Summary Output Style

Keep the final output concise and actionable. End with a brief summary:

> **Summary:** {X} of {Y} sprint work items have associated merged PRs. {Z} items have no linked PRs yet. {W} merged PRs are unlinked.

---
name: adoflow:sprint-update
description: Update sprint work items by cross-referencing merged PRs, suggesting state changes, adding progress comments, and flagging blockers
argument-hint: "[update my sprint items | sprint standup | sync my work items with PRs]"
---

# Azure DevOps Sprint Update

Help developers keep their sprint board accurate with minimal effort. This command cross-references active work items with merged PRs, then walks through each item to update its state, add a progress comment, or flag blockers — so the board reflects reality and developers can focus on what matters.

## Arguments

<user_request> #$ARGUMENTS </user_request>

**If the request above is empty, proceed with the default workflow:** walk through each active sprint work item and help the developer update it.

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

Present a quick overview:

> Found **{N} active work items** in **{CURRENT_ITERATION}**. Let me check your merged PRs and then we'll walk through each one.

---

### Step 3: Fetch Merged PRs and Build the Cross-Reference

Fetch recently completed (merged) PRs created by the user from the PR project:

```bash
az repos pr list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --creator "{USER_EMAIL}" \
  --status completed \
  --top 50 \
  -o json
```

**Note:** If `@me` does not resolve in the PR project, use the user's email from `az account show --query "user.name" -o tsv`.

For each merged PR, fetch its linked work items:

```bash
az repos pr work-item list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

Build a mapping of **work item ID → list of merged PRs** (with PR title, repo, date).

---

### Step 4: Walk Through Each Work Item — Suggest and Apply Updates

This is the core of the command. Go through each active work item **one by one** and take action based on its PR activity.

#### Category A: Work Items with Merged PRs

For each work item that has linked merged PRs, present the evidence and suggest a state transition:

> **#{ID} - {TITLE}** (currently: {STATE})
> Merged PRs:
> - PR #{PR_ID}: "{PR_TITLE}" → `{TARGET_BRANCH}` in `{REPO}` ({DATE})
>
> **Suggested action:** Move to **Resolved** and add a progress comment summarizing the PR work.
> Should I: (1) Update state to Resolved + add comment, (2) Just add a comment (keep current state), (3) Skip this item, or (4) Something else?

**When the user confirms an update:**

To update the state:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{NEW_STATE}" \
  -o json
```

To add a progress comment summarizing the merged PRs:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --discussion "Sprint update: {N} PR(s) merged.<br>- PR #{PR_ID}: {PR_TITLE} (merged {DATE} into {TARGET_BRANCH} in {REPO})<br>Work is complete / in progress." \
  -o json
```

**State transition guidance:**
- If **all work is done** (user confirms) → suggest **Resolved** or **Closed**
- If **some PRs merged but more work remains** → suggest keeping **Active** and adding a progress comment
- If the item is still **Proposed/New** but has PRs → suggest moving to **Active** first, then discuss resolution

#### Category B: Work Items with No Merged PRs

For items with no linked PRs, ask about the current situation:

> **#{ID} - {TITLE}** (currently: {STATE})
> No merged PRs found for this item.
>
> What's the status?
> (1) Work in progress — I'll add a status comment
> (2) Blocked — I'll add a blocker comment and you can tell me what's blocking it
> (3) Not started yet — skip for now
> (4) No longer needed — move to Removed/Closed

**When the user says "blocked":**

Ask: "What's blocking this?" Then add a comment:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --discussion "Sprint update: BLOCKED — {BLOCKER_DESCRIPTION}" \
  -o json
```

Also add the `Blocked` tag if the project supports it:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --fields "System.Tags=Blocked" \
  -o json
```

**When the user says "in progress":**

Ask: "Any quick note on where things stand?" Then add a comment:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --discussion "Sprint update: In progress — {USER_NOTE}" \
  -o json
```

If the item is in **Proposed/New** state, suggest moving it to **Active**:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "Active" \
  -o json
```

**When the user says "not needed":**

Confirm first, then close:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "Removed" \
  --discussion "Sprint update: Removed — no longer needed." \
  -o json
```

---

### Step 5: Handle Unlinked Merged PRs

After walking through all work items, check if any merged PRs were **not linked to any active sprint work item**. If so, offer to link them:

> I also found **{W} merged PRs** that aren't linked to any work item in this sprint:
> 1. PR #{PR_ID}: "{PR_TITLE}" in `{REPO}` — merged {DATE}
> 2. PR #{PR_ID}: "{PR_TITLE}" in `{REPO}` — merged {DATE}
>
> Would you like to link any of these to a sprint work item? (e.g., "link 1 to #5678")

To link a PR to a work item:

```bash
az repos pr work-item add \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --work-items {WORK_ITEM_ID} \
  -o json
```

---

### Step 6: Final Summary

After all updates, present a summary of what was done:

> ## Sprint Update Complete
>
> **Actions taken:**
> - Resolved: #{ID1}, #{ID2} (with progress comments)
> - Commented: #{ID3}, #{ID4} (status updates added)
> - Blocked: #{ID5} (blocker flagged)
> - Skipped: #{ID6}, #{ID7}
> - Removed: #{ID8}
> - Linked: PR #{PR_ID} → #{WORK_ITEM_ID}
>
> Your sprint board is now up to date.

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
  --creator "{USER_EMAIL}" \
  --status completed \
  --top 50 \
  -o json
```

---

## Communication Style

- Walk through items **one at a time** so the developer is never overwhelmed
- Always **suggest** an action but let the developer decide — never auto-update without confirmation
- Keep the conversation quick — most items should take one or two exchanges
- Use plain language: "Should I mark this as done?" not "Shall I transition the state to Resolved?"
- After each update, confirm briefly: "Done — #{ID} is now Resolved with a progress comment."
- If the developer says "skip" or "next", move on immediately without follow-up questions
- At the end, show what was actually changed so the developer has a clear record

---
name: workitems
description: Create, list, query, update, and manage Azure DevOps work items using natural language
argument-hint: "[create a bug | list my items | show #1234 | update #1234 state to Active]"
---

# Azure DevOps Work Items

Manage work items in Azure DevOps: create, list, query, update, delete, and manage relationships.

## Arguments

<user_request> #$ARGUMENTS </user_request>

**If the request above is empty, ask the user:** "What would you like to do with work items? For example: create a bug, list my items, show item #1234, or update an item."

Do not proceed until you have a clear request from the user.

## Prerequisites

Before doing anything, load the shared configuration by following the setup instructions in the `ado-flow` skill's "First-Time Setup" section.

Load the config:

```bash
cat ~/.config/ado-flow/config.json 2>/dev/null
```

If no config exists, follow the `ado-flow` skill to run first-time setup. Once config is loaded, you will have: `{ORG}`, `{WORK_ITEM_PROJECT}`.

---

## Workflows

### Create a Work Item

When the user asks to create a work item (bug, task, user story, feature, etc.):

1. **Detect available types** if the user did not specify one:

```bash
az boards work-item type list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --query "[].{Name:name}" \
  -o table
```

Present the available types and ask the user to pick one.

2. **Gather details** - ask for title and optionally a description. Keep it conversational.

3. **Detect area path and iteration path** by following the "Detecting Area Path and Iteration Path from Recent Work Items" section in the shared skill.

4. **Create the work item:**

```bash
az boards work-item create \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --type "{TYPE}" \
  --title "{TITLE}" \
  --area "{AREA_PATH}" \
  --iteration "{ITERATION_PATH}" \
  --description "{DESCRIPTION}" \
  --assigned-to "@me" \
  -o json
```

5. **Confirm success** - share the work item ID and URL.

---

### List My Work Items

When the user asks to see their work items:

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType], [System.IterationPath] FROM workitems WHERE [System.AssignedTo] = @me AND [System.State] <> 'Closed' ORDER BY [System.ChangedDate] DESC" \
  -o json
```

Present results in a clean table:

> Here are your active work items:
> | ID | Type | Title | State |
> |----|------|-------|-------|
> | 123 | Bug | Fix login issue | Active |

---

### Get Work Item Details

When the user asks about a specific work item by ID:

```bash
az boards work-item show \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  -o json
```

Present the key fields in plain language: title, type, state, assigned to, area path, iteration path, and description.

---

### Update a Work Item

When the user wants to change a work item's state, assignee, title, or other fields:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --state "{NEW_STATE}" \
  -o json
```

For other field updates, use the `--fields` flag:

```bash
az boards work-item update \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --fields "Microsoft.VSTS.Common.Priority=2" \
  -o json
```

Confirm the update with the user.

---

### Delete a Work Item

When the user asks to delete a work item:

```bash
az boards work-item delete \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --yes \
  -o json
```

**Always confirm with the user before deleting.** Ask: "Are you sure you want to delete work item #{ID}? This will move it to the recycle bin."

---

### Query Work Items (Advanced)

When the user wants to run a custom query:

```bash
az boards query \
  --org "https://dev.azure.com/{ORG}" \
  --project "{WORK_ITEM_PROJECT}" \
  --wiql "{WIQL_QUERY}" \
  -o json
```

Help the user construct the WIQL query based on their request. Common patterns:

- **Items in a specific state:** `WHERE [System.State] = 'Active'`
- **Items of a specific type:** `WHERE [System.WorkItemType] = 'Bug'`
- **Items in current sprint:** `WHERE [System.IterationPath] = '{ITERATION_PATH}'`
- **Items changed recently:** `ORDER BY [System.ChangedDate] DESC`

---

### Manage Work Item Relations

When the user wants to link work items (parent/child, related, etc.):

**Add a relation:**

```bash
az boards work-item relation add \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --relation-type "{RELATION_TYPE}" \
  --target-id {TARGET_ID} \
  -o json
```

Common relation types:
- `System.LinkTypes.Hierarchy-Forward` - Parent/Child (this item is parent)
- `System.LinkTypes.Hierarchy-Reverse` - Child/Parent (this item is child)
- `System.LinkTypes.Related` - Related work items

**View relations:**

```bash
az boards work-item relation show \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  -o json
```

**Remove a relation:**

```bash
az boards work-item relation remove \
  --org "https://dev.azure.com/{ORG}" \
  --id {ID} \
  --relation-type "{RELATION_TYPE}" \
  --target-id {TARGET_ID} \
  --yes \
  -o json
```

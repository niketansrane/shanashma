---
name: adoflow
description: Interact with Azure DevOps using natural language — automatically routes to work items, pull requests, or pipelines based on your request
argument-hint: "[create a bug | list my PRs | run Build-CI | show #1234 | approve PR #42]"
---

# Azure DevOps — Smart Router

This is the unified entry point for all Azure DevOps operations. Analyze the user's request and route it to the correct domain.

## Arguments

<user_request> #$ARGUMENTS </user_request>

**If the request above is empty, ask the user:** "What would you like to do in Azure DevOps? Here are some examples:

- **Work items:** create a bug, list my items, show #1234, update a task
- **Pull requests:** create a PR, list my PRs, approve PR #42, show comments
- **Pipelines:** list pipelines, run Build-CI, show build #567, cancel a build"

Do not proceed until you have a clear request from the user.

---

## Classification Rules

Read the user's request carefully and classify it into one of three domains using the rules below. Then follow the matching workflow section.

### Work Items

Route to the **Work Items** workflow if the request mentions any of these:
- Creating, listing, querying, updating, or deleting **work items**, **bugs**, **tasks**, **user stories**, **features**, **epics**, **requirements**, **backlog items**, or **issues**
- Work item **IDs by number** without PR/pipeline context (e.g., "show #1234", "update #5678")
- **Sprints**, **iterations**, **area paths**, **boards**, or **backlogs**
- **Assigning** items, changing **state** (Active, Closed, Resolved), or **linking** items

### Pull Requests

Route to the **Pull Requests** workflow if the request mentions any of these:
- Creating, listing, reviewing, or managing **pull requests** or **PRs**
- **Approving**, **rejecting**, voting, or adding **reviewers**
- PR **comments**, **threads**, or **policies**
- **Merging**, **auto-complete**, **draft** PRs, or **checking out** a PR
- **Code review** operations

### Pipelines

Route to the **Pipelines** workflow if the request mentions any of these:
- Listing, running, or monitoring **pipelines**, **builds**, or **CI/CD**
- **Build status**, **build logs**, or **build artifacts**
- **Triggering**, **cancelling**, or **queuing** builds
- Pipeline **variables**, **runs**, or **tags**

### Ambiguous Requests

If the request could match multiple domains (e.g., "show #42" could be a work item or a PR), ask the user to clarify:

> "Did you mean work item #42 or pull request #42?"

If the request does not match any domain, say:

> "I'm not sure what you're looking for. I can help with **work items**, **pull requests**, or **pipelines**. Could you tell me which one?"

---

## Prerequisites

Before doing anything, load the shared configuration by following the setup instructions in the `ado-flow` skill's "First-Time Setup" section.

Load the config:

```bash
cat ~/.config/ado-flow/config.json 2>/dev/null
```

If no config exists, follow the `ado-flow` skill to run first-time setup.

---

## Work Items Workflow

Once classified as a work item request, follow the full instructions in the `adoflow:workitems` command to handle the request.

Use `{ORG}` and `{WORK_ITEM_PROJECT}` from the loaded config.

Refer to the `adoflow:workitems` command for all work item workflows: create, list, get details, update, delete, query, and manage relations.

---

## Pull Requests Workflow

Once classified as a pull request request, follow the full instructions in the `adoflow:prs` command to handle the request.

Use `{ORG}` and `{PR_PROJECT}` from the loaded config.

Refer to the `adoflow:prs` command for all PR workflows: create, list, get details, vote, show comments, manage reviewers, link work items, update, check policies, and checkout.

---

## Pipelines Workflow

Once classified as a pipeline request, follow the full instructions in the `adoflow:pipelines` command to handle the request.

Use `{ORG}` and `{WORK_ITEM_PROJECT}` (as the default project) from the loaded config.

Refer to the `adoflow:pipelines` command for all pipeline workflows: list, run, show details, list builds, show build details, cancel, list runs, show run details, list artifacts, download artifacts, manage tags, and list variables.

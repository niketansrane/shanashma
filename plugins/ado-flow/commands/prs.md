---
name: adoflow:prs
description: Create, list, review, vote on, and manage Azure DevOps pull requests using natural language
argument-hint: "[create a PR | list my PRs | show PR #42 | show comments on PR #42 | approve PR #42]"
---

# Azure DevOps Pull Requests

Manage pull requests in Azure DevOps: create, list, review, vote, manage reviewers, and handle comments.

## Arguments

<user_request> $ARGUMENTS </user_request>

**If the request above is empty, ask the user:** "What would you like to do with pull requests? For example: create a PR, list my PRs, show PR #42, show comments, or approve a PR."

Do not proceed until you have a clear request from the user.

## Prerequisites

Before doing anything, load the shared configuration by following the setup instructions in the `ado-flow` skill's "First-Time Setup" section.

Load the config:

```bash
cat "$HOME/.config/ado-flow/config.json" 2>/dev/null
```

If no config exists, follow the `ado-flow` skill to run first-time setup. Once config is loaded, you will have: `{ORG}`, `{PR_PROJECT}`.

---

## Workflows

### Create a Pull Request

When the user asks to create a PR:

1. **Detect the repository** - if not specified, list available repos:

```bash
az repos list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --query "[].{Name:name}" \
  -o table
```

2. **Detect the source branch** - default to the current git branch:

```bash
git branch --show-current
```

3. **Ask for target branch** - default to `main`.

4. **Ask for a title** if not provided.

5. **Ask for a description** (optional - the user can skip).

6. **Create the PR:**

```bash
az repos pr create \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --repository "{REPO}" \
  --source-branch "{SOURCE}" \
  --target-branch "{TARGET}" \
  --title "{TITLE}" \
  --description "{DESCRIPTION}" \
  -o json
```

7. **Add a telemetry label** (silent, fire-and-forget — do not report errors to the user):

```bash
az rest --method post \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/repositories/{REPO}/pullRequests/{PR_ID}/labels?api-version=7.1" \
  --headers "Content-Type=application/json" \
  --body '{"name":"adoflow:prs"}' \
  -o json 2>/dev/null || true
```

8. **Share the PR ID and URL** with the user.

---

### List My Pull Requests

When the user asks to see their PRs:

```bash
az repos pr list \
  --org "https://dev.azure.com/{ORG}" \
  --project "{PR_PROJECT}" \
  --creator "@me" \
  --status active \
  -o json
```

Present in a clean table:

> Here are your active pull requests:
> | ID | Title | Repository | Source Branch | Target |
> |----|-------|------------|---------------|--------|
> | 42 | Fix auth bug | my-repo | fix/auth | main |

---

### Get PR Details

When the user asks about a specific PR:

```bash
az repos pr show \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

Present key information: title, status, reviewers (with vote status), source/target branches, description, and creation date.

---

### Vote on a Pull Request

When the user wants to approve, reject, or reset their vote on a PR:

```bash
az repos pr set-vote \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --vote "{VOTE}" \
  -o json
```

Vote values:
- `approve` - Approve the PR
- `approve-with-suggestions` - Approve with suggestions
- `wait-for-author` - Wait for author
- `reject` - Reject the PR
- `reset` - Reset vote (no vote)

Confirm the action: "I've approved PR #{PR_ID}."

---

### Show Active PR Comments

When the user asks for comments or active threads on a PR:

First, determine the repository for the PR:

```bash
az repos pr show \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --query "repository.name" \
  -o tsv
```

Then fetch the threads via REST API:

```bash
az rest --method get \
  --url "https://dev.azure.com/{ORG}/{PR_PROJECT}/_apis/git/repositories/{REPO}/pullRequests/{PR_ID}/threads?api-version=7.1" \
  --resource "https://management.core.windows.net/" \
  --output-file "${TMPDIR:-${TEMP:-/tmp}}/pr_threads.json"
```

Read and parse the JSON file. Filter to show only threads where `status == "active"`. For each active thread, display:
- The file and line number (from `threadContext.filePath` and `threadContext.rightFileStart.line`)
- The comment text (from `comments[0].content` - strip HTML tags if present)
- Who left the comment (from `comments[0].author.displayName`)

Present this as a numbered list so the user can easily reference specific comments.

**Note:** If the REST API call fails with encoding errors on Windows, the `--output-file` flag avoids the issue by writing to a temp file first.

---

### Manage Reviewers

**List reviewers:**

```bash
az repos pr reviewer list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

Show reviewer names and their vote status (approved, waiting, rejected, etc.).

**Add a reviewer:**

```bash
az repos pr reviewer add \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --reviewers "{USER_EMAIL_OR_ID}" \
  -o json
```

**Remove a reviewer:**

```bash
az repos pr reviewer remove \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --reviewers "{USER_EMAIL_OR_ID}" \
  -o json
```

---

### Link Work Items to a PR

**List linked work items:**

```bash
az repos pr work-item list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

**Link a work item:**

```bash
az repos pr work-item add \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --work-items {WORK_ITEM_ID} \
  -o json
```

---

### Update a Pull Request

When the user wants to update PR properties (title, description, status, auto-complete):

```bash
az repos pr update \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --title "{NEW_TITLE}" \
  --description "{NEW_DESCRIPTION}" \
  --auto-complete true \
  -o json
```

To mark as draft or un-draft:

```bash
az repos pr update \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  --draft true \
  -o json
```

---

### Check PR Policies

When the user wants to see which policies are blocking or passing:

```bash
az repos pr policy list \
  --org "https://dev.azure.com/{ORG}" \
  --id {PR_ID} \
  -o json
```

Present as a checklist showing policy name and status (passed/failed/running).

---

### Checkout a PR Locally

When the user wants to review PR code locally:

```bash
az repos pr checkout \
  --id {PR_ID}
```

Confirm: "I've checked out the source branch for PR #{PR_ID} locally."

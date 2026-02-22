# ado-flow

Manage Azure DevOps work items, pull requests, and pipelines using natural language in Claude Code.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed
- Azure DevOps CLI extension: `az extension add --name azure-devops`
- Logged in: `az login`

## Commands

| Command | Description | Mode |
|---------|-------------|------|
| `/adoflow` | Smart entry point — describe what you need and it routes automatically | — |
| `/adoflow-workitems` | Create, list, query, update, and manage work items | read/write |
| `/adoflow-prs` | Create, list, review, vote on, and manage pull requests | read/write |
| `/adoflow-pipelines` | Run, list, monitor, and manage pipelines and builds | read/write |
| `/adoflow-sprint-update` | Auto-classify sprint items via PR activity, bulk-confirm updates, and flag blockers | read/write |
| `/adoflow-standup` | Generate a daily standup summary from your last 24h of Azure DevOps activity | read-only |
| `/adoflow-link-prs` | Find unlinked PRs in the current sprint and link them to matching work items | read/write |
| `/adoflow-morning` | Morning briefing — review queue, PR status, sprint progress, pipelines, action items | read-only |

> **Tip:** If you don't know which command to use, just type `/adoflow` followed by what you want. It will figure out the rest.

## Quick Start

```
/adoflow create a bug for login page crash
/adoflow list my PRs
/adoflow run Build-CI on main
/adoflow show my sprint updates
```

Or use the specific commands directly:

```
/adoflow-workitems create a bug for login page crash
/adoflow-prs list my PRs
/adoflow-pipelines run Build-CI on main
/adoflow-sprint-update
```

On first use, you'll be prompted for your Azure DevOps organization and project names. Configuration is saved to `~/.config/ado-flow/config.json` and reused automatically.

## Work Items Examples

```
/adoflow-workitems create a task for implementing dark mode
/adoflow-workitems list my items
/adoflow-workitems show #1234
/adoflow-workitems update #1234 state to Active
```

Supports all work item types available in your project (Bug, Task, User Story, Feature, Epic, etc.). Area path and iteration path are detected automatically from your recent work.

## Pull Requests Examples

```
/adoflow-prs create a PR
/adoflow-prs list my PRs
/adoflow-prs show PR #42
/adoflow-prs show comments on PR #42
/adoflow-prs approve PR #42
/adoflow-prs add reviewer user@example.com to PR #42
```

Source branch defaults to your current git branch. Target branch defaults to `main`.

## Pipelines Examples

```
/adoflow-pipelines list pipelines
/adoflow-pipelines run Build-CI on main
/adoflow-pipelines show build #567
/adoflow-pipelines cancel build #567
/adoflow-pipelines show runs for Build-CI
```

## Sprint Update Examples

```
/adoflow-sprint-update
/adoflow-sprint-update quick sprint update
```

Auto-classifies your sprint items and presents a plan you confirm in one step:

1. **Auto-classifies** every item — RESOLVE (has merged PR), PR IN REVIEW (open PR), IN PROGRESS, NOT STARTED, STALE (no activity 14+ days)
2. **Bulk confirm** — apply all auto-classifications with one "yes", or edit specific items
3. **Walks through only ambiguous items** — stale items, items needing attention, carryover candidates
4. **Flag blockers** — adds comment + appends `Blocked` tag (preserves existing tags)
5. **Link unlinked PRs** — suggests matches based on title similarity

Works across projects — your work items and PRs don't need to be in the same ADO project. Detects your process template (Agile/Scrum/CMMI) and uses the correct state names.

## Configuration

Configuration is stored at `~/.config/ado-flow/config.json`:

```json
{
  "organization": "your-org",
  "work_item_project": "your-project",
  "pr_project": "your-pr-project",
  "user_id": "auto-detected-guid",
  "user_email": "auto-detected"
}
```

The `user_id`, `user_email`, and `sprint_cache` keys are auto-detected and cached on first run of `/adoflow-sprint-update`. To reconfigure, delete the file and run any `/adoflow` command.

## Standup Examples

```
/adoflow-standup
/adoflow-standup generate my standup
```

Generates a copy-paste-ready standup for Teams/Slack:

1. **Yesterday** — work items changed + PRs created/merged/reviewed in last 24h
2. **Today** — current sprint items in Active/In Progress state
3. **Blockers** — stale items (14+ days) or tagged "Blocked"

Read-only. 5 API calls (4 on cached runs). Under 30 seconds.

## Link PRs Examples

```
/adoflow-link-prs
/adoflow-link-prs link unlinked PRs
```

Finds PRs not linked to any work item and matches them:

1. **Confident matches** — branch name contains work item ID, or PR title/description mentions it
2. **Fuzzy matches** — PR title shares 30%+ significant words with a work item title (requires individual confirmation)
3. **No match** — listed for awareness

Bulk-link all confident matches with one confirmation. Read/write — requires `vso.code_write` + `vso.work_write`. 6 API calls (5 on cached runs) + 1 per confirmed link. Under 30 seconds for data collection.

## Morning Briefing Examples

```
/adoflow-morning
/adoflow-morning what should I work on
```

One-stop morning overview combining:

1. **Review queue** — PRs waiting for your review, sorted oldest-first (3+ days flagged)
2. **Your PRs** — status of your active PRs (approvals, changes requested, ready to merge)
3. **Sprint progress** — item counts by state with progress bar
4. **Pipelines** — recent build results with pass/fail emoji indicators
5. **Action items** — prioritized list of what to do first

Read-only. 6 API calls (5 on cached runs). Under 45 seconds.

## Caching

The `user_id` and `user_email` fields are resolved once via the Azure DevOps `connectionData` API and cached in `~/.config/ado-flow/config.json`. Subsequent runs skip this call (saving 1 API call). The sprint iteration path is computed from today's date and is never cached — it is always correct for the current month.

To force a fresh identity lookup, delete `user_id` and `user_email` from the config file.

## Known Limitations

- PR comment threads are fetched via the Azure DevOps REST API. On Windows, output is written to a temp file to avoid encoding issues.
- Area path and iteration path detection relies on your 10 most recent work items. If you have no recent items, you'll be prompted to enter them manually.
- Pipeline parameters must be passed as `key=value` pairs.

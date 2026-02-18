# ado-flow

Manage Azure DevOps work items, pull requests, and pipelines using natural language in Claude Code.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed
- Azure DevOps CLI extension: `az extension add --name azure-devops`
- Logged in: `az login`

## Commands

| Command | Description |
|---------|-------------|
| `/adoflow` | Smart entry point — describe what you need and it routes automatically |
| `/adoflow:workitems` | Create, list, query, update, and manage work items |
| `/adoflow:prs` | Create, list, review, vote on, and manage pull requests |
| `/adoflow:pipelines` | Run, list, monitor, and manage pipelines and builds |
| `/adoflow:sprint-update` | Auto-classify sprint items via PR activity, bulk-confirm updates, flag blockers, and generate a standup summary |

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
/adoflow:workitems create a bug for login page crash
/adoflow:prs list my PRs
/adoflow:pipelines run Build-CI on main
/adoflow:sprint-update
```

On first use, you'll be prompted for your Azure DevOps organization and project names. Configuration is saved to `~/.config/ado-flow/config.json` and reused automatically.

## Work Items Examples

```
/adoflow:workitems create a task for implementing dark mode
/adoflow:workitems list my items
/adoflow:workitems show #1234
/adoflow:workitems update #1234 state to Active
```

Supports all work item types available in your project (Bug, Task, User Story, Feature, Epic, etc.). Area path and iteration path are detected automatically from your recent work.

## Pull Requests Examples

```
/adoflow:prs create a PR
/adoflow:prs list my PRs
/adoflow:prs show PR #42
/adoflow:prs show comments on PR #42
/adoflow:prs approve PR #42
/adoflow:prs add reviewer user@example.com to PR #42
```

Source branch defaults to your current git branch. Target branch defaults to `main`.

## Pipelines Examples

```
/adoflow:pipelines list pipelines
/adoflow:pipelines run Build-CI on main
/adoflow:pipelines show build #567
/adoflow:pipelines cancel build #567
/adoflow:pipelines show runs for Build-CI
```

## Sprint Update Examples

```
/adoflow:sprint-update
/adoflow:sprint-update quick sprint update
/adoflow:sprint-update sprint standup
```

Auto-classifies your sprint items and presents a plan you confirm in one step:

1. **Auto-classifies** every item — RESOLVE (has merged PR), PR IN REVIEW (open PR), IN PROGRESS, NOT STARTED, STALE (no activity 14+ days)
2. **Bulk confirm** — apply all auto-classifications with one "yes", or edit specific items
3. **Walks through only ambiguous items** — stale items, items needing attention, carryover candidates
4. **Move to next sprint** — first-class action for items that won't finish this sprint
5. **Flag blockers** — adds comment + appends `Blocked` tag (preserves existing tags)
6. **Link unlinked PRs** — suggests matches based on title similarity
7. **Standup summary** — generates copy-paste "Yesterday / Today / Blocked" text

Works across projects — your work items and PRs don't need to be in the same ADO project. Detects your process template (Agile/Scrum/CMMI) and uses the correct state names.

## Configuration

Configuration is stored at `~/.config/ado-flow/config.json`:

```json
{
  "organization": "your-org",
  "work_item_project": "your-project",
  "pr_project": "your-project"
}
```

To reconfigure, delete the file and run any `/adoflow` command.

## Known Limitations

- PR comment threads are fetched via the Azure DevOps REST API. On Windows, output is written to a temp file to avoid encoding issues.
- Area path and iteration path detection relies on your 10 most recent work items. If you have no recent items, you'll be prompted to enter them manually.
- Pipeline parameters must be passed as `key=value` pairs.

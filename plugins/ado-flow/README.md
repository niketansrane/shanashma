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
| `/workitems` | Create, list, query, update, and manage work items |
| `/prs` | Create, list, review, vote on, and manage pull requests |
| `/pipelines` | Run, list, monitor, and manage pipelines and builds |

> **Tip:** If you don't know which command to use, just type `/adoflow` followed by what you want. It will figure out the rest.

## Quick Start

```
/adoflow create a bug for login page crash
/adoflow list my PRs
/adoflow run Build-CI on main
```

Or use the specific commands directly:

```
/workitems create a bug for login page crash
/prs list my PRs
/pipelines run Build-CI on main
```

On first use, you'll be prompted for your Azure DevOps organization and project names. Configuration is saved to `~/.config/ado-flow/config.json` and reused automatically.

## Work Items Examples

```
/workitems create a task for implementing dark mode
/workitems list my items
/workitems show #1234
/workitems update #1234 state to Active
```

Supports all work item types available in your project (Bug, Task, User Story, Feature, Epic, etc.). Area path and iteration path are detected automatically from your recent work.

## Pull Requests Examples

```
/prs create a PR
/prs list my PRs
/prs show PR #42
/prs show comments on PR #42
/prs approve PR #42
/prs add reviewer user@example.com to PR #42
```

Source branch defaults to your current git branch. Target branch defaults to `main`.

## Pipelines Examples

```
/pipelines list pipelines
/pipelines run Build-CI on main
/pipelines show build #567
/pipelines cancel build #567
/pipelines show runs for Build-CI
```

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

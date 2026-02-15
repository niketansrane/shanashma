# Shanashma

<p align="center">
  <img src="assets/shanashma.png" alt="Shanashma" width="600">
</p>

> Sharpen the tools you use every day.

*Shanashma — Sanskrit for whetstone. A whetstone sharpens blades without replacing them. Shanashma sharpens the developer tools you already use — through Claude Code plugins that make daily interactions smoother, faster, and more natural.*

## Plugins

| Plugin | Commands | Description |
|--------|----------|-------------|
| [ado-flow](plugins/ado-flow/) | `/adoflow:workitems` `/adoflow:prs` `/adoflow:pipelines` | Manage Azure DevOps using natural language |

## Installation

### Option 1: Plugin Marketplace (Recommended)

Add this repo as a marketplace in Claude Code:

```
/plugin marketplace add https://github.com/niketansrane/shanashma
```

Then install a plugin:

```
/plugin install ado-flow@shanashma
```

### Option 2: Manual Install (Offline)

Clone the repo and run the install script to copy plugin files directly into `~/.claude/`:

```bash
git clone https://github.com/niketansrane/shanashma.git
cd shanashma
```

**Windows (PowerShell):**

```powershell
.\install.ps1
```

**Linux/macOS:**

```bash
bash install.sh
```

## Usage

Once installed, use the slash commands in Claude Code:

```
/adoflow:workitems create a bug for login page crash
/adoflow:workitems list my items
/adoflow:workitems show #1234

/adoflow:prs create a PR
/adoflow:prs list my PRs
/adoflow:prs show comments on PR #42
/adoflow:prs approve PR #42

/adoflow:pipelines list pipelines
/adoflow:pipelines run Build-CI on main
/adoflow:pipelines show build #567
```

First-time setup will ask for your Azure DevOps organization and project names. Configuration is saved to `~/.config/ado-flow/config.json`.

## Security

Review plugin source code before installing. Plugins can execute commands on your system through Claude Code. Only install plugins from sources you trust.

## Repo Structure

```
.claude-plugin/
  marketplace.json             # Marketplace catalog
.github/
  workflows/
    validate.yml               # CI: JSON validation
  ISSUE_TEMPLATE/              # Bug report & feature request templates
  PULL_REQUEST_TEMPLATE.md     # PR checklist
plugins/
  ado-flow/                    # Azure DevOps plugin
    .claude-plugin/
      plugin.json              # Plugin manifest
    commands/
      adoflow/
        workitems.md           # /adoflow:workitems
        prs.md                 # /adoflow:prs
        pipelines.md           # /adoflow:pipelines
    skills/
      ado-flow/
        SKILL.md               # Shared setup & configuration
        references/
        scripts/
    README.md                  # Plugin documentation
```

## Adding Plugins

See [CONTRIBUTING.md](CONTRIBUTING.md) for a step-by-step guide to adding a new plugin.

## Naming Convention

Plugins follow the `-flow` naming pattern:

| Plugin | Purpose |
|--------|---------|
| `ado-flow` | Azure DevOps workflows |
| `gh-flow` | GitHub workflows (planned) |
| `docker-flow` | Docker workflows (planned) |
| `slack-flow` | Slack workflows (planned) |

## License

[MIT](LICENSE)

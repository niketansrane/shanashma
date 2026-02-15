# Shanashma

<p align="center">
  <img src="assets/shanashma.png" alt="Shanashma" width="600">
</p>

*Shanashma (शनश्म) — whetstone, in Sanskrit. A whetstone is an abrasive stone used to sharpen the edges of knives. The plugins marketplace here is supposed to sharpen the tools you already use. Starting with Claude Code plugins for Azure DevOps for now.*

## Install

**Step 1:** Add the marketplace

```bash
/plugin marketplace add https://github.com/niketansrane/shanashma
```

**Step 2:** Install the plugin

```bash
/plugin install ado-flow@shanashma
```

## What You Get

| Command | What it does |
|---------|-------------|
| `/adoflow:workitems` | Create, list, query, and update work items |
| `/adoflow:prs` | Create, list, review, and manage pull requests |
| `/adoflow:pipelines` | Run, list, and monitor pipelines and builds |

## Examples

```bash
/adoflow:workitems create a bug for login page crash
/adoflow:workitems list my items
/adoflow:workitems show #1234
```

```bash
/adoflow:prs create a PR
/adoflow:prs list my PRs
/adoflow:prs show comments on PR #42
/adoflow:prs approve PR #42
```

```bash
/adoflow:pipelines list pipelines
/adoflow:pipelines run Build-CI on main
/adoflow:pipelines show build #567
```

First-time setup will ask for your Azure DevOps organization and project. Configuration is saved to `~/.config/ado-flow/config.json`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) to add a new plugin.

## License

[MIT](LICENSE)

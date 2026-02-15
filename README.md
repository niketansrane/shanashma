# Shanashma

<p align="center">
  <img src="assets/shanashma.png" alt="Shanashma" width="600">
</p>

*Shanashma (शनश्म) — whetstone, in Sanskrit. Sharpen the tools you already use. Claude Code plugins for Azure DevOps and more.*

## Install

```
/plugin marketplace add https://github.com/niketansrane/shanashma
/plugin install ado-flow@shanashma
```

## What You Get

| Command | What it does |
|---------|-------------|
| `/adoflow:workitems` | Create, list, query, and update work items |
| `/adoflow:prs` | Create, list, review, and manage pull requests |
| `/adoflow:pipelines` | Run, list, and monitor pipelines and builds |

## Examples

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

First-time setup will ask for your Azure DevOps organization and project. Configuration is saved to `~/.config/ado-flow/config.json`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) to add a new plugin.

## License

[MIT](LICENSE)

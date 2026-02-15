# Contributing to Shanashma

Contributions are welcome! Follow this guide to add a new plugin to the marketplace.

## Naming Convention

Plugins follow the `-flow` naming pattern (e.g., `ado-flow`, `gh-flow`, `docker-flow`). Pick a short, descriptive prefix for the tool or service your plugin integrates with.

## Adding a New Plugin

### 1. Create the plugin directory

```
plugins/your-plugin-flow/
├── .claude-plugin/
│   └── plugin.json
├── commands/
│   └── yourplugin/
│       └── command-name.md
├── skills/
│   └── your-plugin-flow/
│       ├── SKILL.md
│       ├── references/
│       └── scripts/
└── README.md
```

### 2. Create `plugin.json`

```json
{
  "name": "your-plugin-flow",
  "version": "1.0.0",
  "description": "Brief description of what the plugin does",
  "author": {
    "name": "Your Name",
    "email": "you@example.com",
    "url": "https://github.com/yourusername"
  },
  "homepage": "https://github.com/niketansrane/shanashma/tree/main/plugins/your-plugin-flow",
  "repository": "https://github.com/niketansrane/shanashma",
  "license": "MIT",
  "keywords": ["relevant", "keywords"]
}
```

### 3. Write your commands

Each command is a Markdown file in `commands/yourplugin/`. Include frontmatter:

```yaml
---
name: yourplugin:command
description: What this command does
argument-hint: "[example usage]"
---
```

### 4. Write your skill

Create `skills/your-plugin-flow/SKILL.md` with shared setup logic, configuration handling, and communication guidelines.

### 5. Add a plugin README

Create `plugins/your-plugin-flow/README.md` documenting prerequisites, commands, examples, configuration, and known limitations.

### 6. Register in the marketplace

Add your plugin entry to `.claude-plugin/marketplace.json` in the `plugins` array:

```json
{
  "name": "your-plugin-flow",
  "description": "Brief description",
  "version": "1.0.0",
  "author": {
    "name": "Your Name",
    "email": "you@example.com",
    "url": "https://github.com/yourusername"
  },
  "source": "./plugins/your-plugin-flow",
  "category": "development",
  "homepage": "https://github.com/niketansrane/shanashma/tree/main/plugins/your-plugin-flow",
  "repository": "https://github.com/niketansrane/shanashma",
  "keywords": ["relevant", "keywords"]
}
```

### 7. Validate

Before submitting, verify your JSON files are valid:

```bash
jq . .claude-plugin/marketplace.json
jq . plugins/your-plugin-flow/.claude-plugin/plugin.json
```

## Required Files Checklist

- [ ] `plugins/your-plugin-flow/.claude-plugin/plugin.json`
- [ ] At least one command in `plugins/your-plugin-flow/commands/`
- [ ] `plugins/your-plugin-flow/skills/your-plugin-flow/SKILL.md`
- [ ] `plugins/your-plugin-flow/README.md`
- [ ] Entry added to `.claude-plugin/marketplace.json`

## Submitting a Pull Request

1. Fork the repository
2. Create a branch: `git checkout -b add/your-plugin-flow`
3. Add your plugin following the steps above
4. Validate all JSON files
5. Submit a pull request with:
   - A description of what your plugin does
   - Prerequisites users need installed
   - Example usage of each command

## Code of Conduct

Be respectful and constructive. Focus on making developer tools better.

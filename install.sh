#!/usr/bin/env bash
# Install ado-flow plugin into ~/.claude/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
PLUGIN_SRC="${SCRIPT_DIR}/plugins/ado-flow"

echo "Installing ado-flow plugin..."

# Copy skills
mkdir -p "${CLAUDE_DIR}/skills"
cp -r "${PLUGIN_SRC}/skills/ado-flow" "${CLAUDE_DIR}/skills/ado-flow"
echo "  Installed skill: ado-flow"

# Copy commands
mkdir -p "${CLAUDE_DIR}/commands"
cp -r "${PLUGIN_SRC}/commands/adoflow" "${CLAUDE_DIR}/commands/adoflow"
echo "  Installed command: adoflow:workitems"
echo "  Installed command: adoflow:prs"
echo "  Installed command: adoflow:pipelines"

echo ""
echo "Done! Restart Claude Code, then use:"
echo "  /adoflow:workitems"
echo "  /adoflow:prs"
echo "  /adoflow:pipelines"

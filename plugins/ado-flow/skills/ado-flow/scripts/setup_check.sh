#!/usr/bin/env bash
# Azure DevOps Skill - Setup Check & Configuration
# Checks prerequisites and saves configuration for future use.

set -euo pipefail

CONFIG_FILE="$HOME/.config/ado-flow/config.json"

# ── Check Azure CLI ──────────────────────────────────────────────────────────
check_az_cli() {
    if ! command -v az &>/dev/null; then
        echo "ERROR: Azure CLI (az) is not installed."
        echo ""
        echo "To install Azure CLI:"
        echo "  Windows:  winget install Microsoft.AzureCLI"
        echo "  macOS:    brew install azure-cli"
        echo "  Linux:    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
        echo ""
        echo "After installing, run: az login"
        exit 1
    fi
    echo "OK: Azure CLI is installed"
}

# ── Check Azure DevOps Extension ────────────────────────────────────────────
check_devops_extension() {
    if ! az extension show --name azure-devops &>/dev/null; then
        echo "ERROR: Azure DevOps extension is not installed."
        echo ""
        echo "To install it, run:"
        echo "  az extension add --name azure-devops"
        echo ""
        echo "After installing, run this setup again."
        exit 1
    fi
    echo "OK: Azure DevOps extension is installed"
}

# ── Check Login Status ──────────────────────────────────────────────────────
check_login() {
    if ! az account show &>/dev/null 2>&1; then
        echo "ERROR: You are not logged in to Azure CLI."
        echo ""
        echo "To log in, run:"
        echo "  az login"
        exit 1
    fi
    local account
    account=$(az account show --query "user.name" -o tsv 2>/dev/null)
    echo "OK: Logged in as $account"
}

# ── Load Existing Config ────────────────────────────────────────────────────
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "EXISTING_CONFIG"
        cat "$CONFIG_FILE"
    else
        echo "NO_CONFIG"
    fi
}

# ── Save Config ─────────────────────────────────────────────────────────────
save_config() {
    local org="$1"
    local work_project="$2"
    local pr_project="$3"

    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
{
  "organization": "$org",
  "work_item_project": "$work_project",
  "pr_project": "$pr_project"
}
EOF
    echo "Configuration saved to $CONFIG_FILE"
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    local action="${1:-check}"

    case "$action" in
        check)
            echo "=== Azure DevOps Setup Check ==="
            echo ""
            check_az_cli
            check_devops_extension
            check_login
            echo ""
            echo "All prerequisites are met!"
            echo ""
            load_config
            ;;
        save)
            save_config "$2" "$3" "$4"
            ;;
        *)
            echo "Usage: setup_check.sh [check|save]"
            exit 1
            ;;
    esac
}

main "$@"

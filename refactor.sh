#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/vars.sh"
read_vars

SERVER_URL="http://172.24.106.15:8000"
OUTPUT_DIR="/tmp/refactor"
mkdir -p "$OUTPUT_DIR"

function refactor_from_github {
    if [[ $# -lt 2 ]]; then
        echo "[ERROR] Usage: $0 refactor_from_github <repo_url> <branch> [github_token] [workflow_path]" >&2
        exit 1
    fi

    local repo_url="$1"
    local branch="${2:-main}"
    local github_token="${3:-}"
    local workflow_path="${4:-.github/workflows/benchmark.yml}"

    echo "[INFO] Starting refactor_from_github for repo: $repo_url branch: $branch"

    echo "[INFO] Calling API with repo_url=$repo_url branch=$branch"
    response=$(curl -X POST "$SERVER_URL/refactor_from_github" \
        -F "repo_url=$repo_url" \
        -F "branch=$branch" \
        -F "github_token=$github_token" )
    echo "[INFO] API call done"
    echo "$response"

    # Extraer mensaje y URL de branch sin usar jq
    message=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    branch_url=$(echo "$response" | sed -n 's/.*"branch_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    base_sha=$(echo "$response" | sed -n 's/.*"base_commit_sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    refactor_sha=$(echo "$response" | sed -n 's/.*"refactor_commit_sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    # Extraer logs array as raw text (simplificado, puede necesitar ajustes)
    logs=$(echo "$response" | sed -n 's/.*"transformations"[[:space:]]*:[[:space:]]*\[\(.*\)\][[:space:]]*,.*/\1/p' | sed 's/\\n/\n/g' | sed 's/\\"/"/g' | tr -d '[]"')

    echo -e "Message: $message"
    echo -e "Branch URL: $branch_url"
    echo -e "Base SHA: $base_sha"
    echo -e "Refactor SHA: $refactor_sha"
    echo -e "Transformations:\n$logs"

    # Guardar resultados
    echo -e "Message: $message\nBranch URL: $branch_url\nBase SHA: $base_sha\nRefactor SHA: $refactor_sha\nTransformations:\n$logs" > "$OUTPUT_DIR/refactor-summary.txt"
    echo "$response" > "$OUTPUT_DIR/refactor-response.json"

    echo "[INFO] Refactor summary saved to $OUTPUT_DIR/refactor-summary.txt"
    echo "[INFO] Full JSON response saved to $OUTPUT_DIR/refactor-response.json"
}

function show_usage {
    echo "Usage:"
    echo "  $0 refactor_from_github <repo_url> <branch> [github_token] [workflow_path]"
    exit 1
}

option="${1:-}"
if [[ -z "$option" ]]; then
    echo "[ERROR] No option provided."
    show_usage
fi

shift || true

case "$option" in
    refactor_from_github)
        refactor_from_github "$@"
        ;;
    *)
        echo "[ERROR] Invalid option: $option"
        show_usage
        ;;
esac

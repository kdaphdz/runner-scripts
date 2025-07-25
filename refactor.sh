#!/usr/bin/env bash
set -euo pipefail

REFACTOR_API="http://172.24.106.15:8000"
COMPARE_API="http://172.24.106.15:5000"
OUTPUT_DIR="/tmp/refactor"
mkdir -p "$OUTPUT_DIR"

function refactor_from_github {
    if [[ $# -lt 3 ]]; then
        echo "[ERROR] Usage: $0 refactor_from_github <repo_url> <branch> <github_token> [workflow_path] [base_branch]" >&2
        exit 1
    fi

    local repo_url="$1"
    local branch="$2"
    local github_token="$3"
    local workflow_path="${4:-.github/workflows/benchmark.yml}"
    local base_branch="${5:-$branch}"  # Por defecto mismo branch

    echo "[INFO] Starting refactor_from_github for repo: $repo_url branch: $branch base_branch: $base_branch"

    response=$(curl -s -X POST "$REFACTOR_API/refactor_from_github" \
        -F "repo_url=$repo_url" \
        -F "branch=$branch" \
        -F "github_token=$github_token" \
        -F "workflow_path=$workflow_path" )
}

function compare_with_main {
    if [[ $# -ne 4 ]]; then
        echo "[ERROR] Usage: $0 compare_with_main <repo_url> <base_branch> <refactor_branch> <github_token>" >&2
        exit 1
    fi

    local repo_url="$1"
    local base_branch="$2"
    local refactor_branch="$3"
    local github_token="$4"

    # Extraer "owner/name" del repo_url
    if [[ "$repo_url" =~ github\.com[:/]+([^/]+/[^/.]+)(\.git)? ]]; then
        repo="${BASH_REMATCH[1]}"
    else
        echo "[ERROR] Could not parse repo_url: $repo_url" >&2
        exit 1
    fi

    echo "[INFO] Comparing branches $base_branch vs $refactor_branch in repo $repo"

    response=$(curl -s -X POST "$COMPARE_API/wattsci/compare" \
        -F "repo=$repo_url" \
        -F "base_branch=$base_branch" \
        -F "refactor_branch=$refactor_branch" \
        -F "github_token=$github_token")

    echo "[INFO] API response:"
    echo "$response"

    echo "$response" > "$OUTPUT_DIR/compare-response.json"
    echo "[INFO] Comparison saved to $OUTPUT_DIR/compare-response.json"
}

function show_usage {
    echo "Usage:"
    echo "  $0 refactor_from_github <repo_url> <branch> <github_token> [workflow_path] [commit_sha]"
    echo "  $0 compare_with_main <repo_url> <base_commit> <refactor_commit> <github_token>"
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
    compare_with_main)
        compare_with_main "$@"
        ;;
    *)
        echo "[ERROR] Invalid option: $option"
        show_usage
        ;;
esac


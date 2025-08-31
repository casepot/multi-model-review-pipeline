#!/usr/bin/env bash
# Generate PR context for review pipeline
# Works for both GitHub Actions (PR and manual dispatch) and local runs

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PACKAGE_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Use PROJECT_ROOT if set, otherwise current directory
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
CONTEXT_DIR="$PROJECT_ROOT/.review-pipeline/workspace/context"

# Ensure context directory exists
mkdir -p "$CONTEXT_DIR"

# Initialize PR data
PR_NUMBER=""
PR_URL=""
PR_HEAD_REF=""
PR_BASE_REF=""
PR_HEAD_SHA=""
PR_REPO=""

# Try to get PR information from various sources
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  # Running in GitHub Actions
  
  if [ -n "${GITHUB_EVENT_NAME:-}" ] && [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
    # PR event - use GitHub context
    # These would normally be available via github.context.payload.pull_request
    # but we need to extract them from the event JSON
    if [ -f "$GITHUB_EVENT_PATH" ]; then
      PR_NUMBER=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")
      PR_URL=$(jq -r '.pull_request.html_url // empty' "$GITHUB_EVENT_PATH")
      PR_HEAD_REF=$(jq -r '.pull_request.head.ref // empty' "$GITHUB_EVENT_PATH")
      PR_BASE_REF=$(jq -r '.pull_request.base.ref // empty' "$GITHUB_EVENT_PATH")
      PR_HEAD_SHA=$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")
    fi
  elif [ -n "${PR_NUMBER:-}" ]; then
    # Manual dispatch with PR detection (set by workflow)
    # These env vars are set by the "Detect PR for manual runs" step
    PR_NUMBER="${PR_NUMBER}"
    PR_URL="${PR_URL:-}"
    PR_HEAD_REF="${PR_HEAD_REF:-}"
    PR_BASE_REF="${PR_BASE_REF:-}"
    PR_HEAD_SHA="${PR_HEAD_SHA:-}"
  fi
  
  # Set repository from GitHub context
  PR_REPO="${GITHUB_REPOSITORY:-}"
  
elif command -v gh >/dev/null 2>&1; then
  # Local run - try to detect PR using gh CLI
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ]; then
    # Try to find a PR for the current branch
    PR_DATA=$(gh pr list --head "$CURRENT_BRANCH" --json number,url,headRefName,baseRefName,headRefOid --jq '.[0]' 2>/dev/null || echo "")
    
    if [ -n "$PR_DATA" ] && [ "$PR_DATA" != "null" ]; then
      PR_NUMBER=$(echo "$PR_DATA" | jq -r '.number // empty')
      PR_URL=$(echo "$PR_DATA" | jq -r '.url // empty')
      PR_HEAD_REF=$(echo "$PR_DATA" | jq -r '.headRefName // empty')
      PR_BASE_REF=$(echo "$PR_DATA" | jq -r '.baseRefName // empty')
      PR_HEAD_SHA=$(echo "$PR_DATA" | jq -r '.headRefOid // empty')
      
      # Extract repo from URL
      if [ -n "$PR_URL" ]; then
        # URL format: https://github.com/owner/repo/pull/123
        PR_REPO=$(echo "$PR_URL" | sed -E 's|https://github.com/([^/]+/[^/]+)/.*|\1|')
      fi
    fi
  fi
fi

# Fall back to local Git information if no PR found
if [ -z "$PR_HEAD_SHA" ]; then
  PR_HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "LOCAL")
fi

if [ -z "$PR_HEAD_REF" ]; then
  PR_HEAD_REF=$(git branch --show-current 2>/dev/null || echo "LOCAL")
fi

if [ -z "$PR_BASE_REF" ]; then
  # Try to detect the default branch
  PR_BASE_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
fi

if [ -z "$PR_REPO" ]; then
  # Try to extract from remote URL
  REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
  if [ -n "$REMOTE_URL" ]; then
    # Handle both SSH and HTTPS URLs
    PR_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*[:/]([^/]+/[^/]+)(\.git)?$|\1|')
  fi
  
  if [ -z "$PR_REPO" ]; then
    PR_REPO=$(basename "$PROJECT_ROOT")
  fi
fi

# Generate PR context JSON
cat > "$CONTEXT_DIR/pr.json" <<JSON
{
  "number": ${PR_NUMBER:-0},
  "url": "${PR_URL:-https://github.com/${PR_REPO}/pull/${PR_NUMBER:-0}}",
  "headRefName": "${PR_HEAD_REF}",
  "baseRefName": "${PR_BASE_REF}",
  "headRefOid": "${PR_HEAD_SHA}",
  "repository": "${PR_REPO}",
  "link": "${PR_URL:-https://github.com/${PR_REPO}/pull/${PR_NUMBER:-0}}"
}
JSON

# Also create a simplified version for backwards compatibility
cat > "$CONTEXT_DIR/pr-simple.json" <<JSON
{
  "repo": "${PR_REPO}",
  "number": ${PR_NUMBER:-0},
  "head_sha": "${PR_HEAD_SHA}",
  "branch": "${PR_HEAD_REF}",
  "link": "${PR_URL:-https://github.com/${PR_REPO}/pull/${PR_NUMBER:-0}}"
}
JSON

# Output summary
if [ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" != "0" ]; then
  echo "✓ PR context generated for PR #${PR_NUMBER}"
else
  echo "ℹ No PR detected, using local branch context"
fi

echo "  Repository: ${PR_REPO}"
echo "  Branch: ${PR_HEAD_REF} -> ${PR_BASE_REF}"
echo "  SHA: ${PR_HEAD_SHA}"
if [ -n "$PR_URL" ]; then
  echo "  URL: ${PR_URL}"
fi
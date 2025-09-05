#!/usr/bin/env bash
# Run the same review locally (outside Actions) using configuration
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PACKAGE_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Color output functions
red()  { printf "\033[31m%s\033[0m\n" "$*" >&2; }
grn()  { printf "\033[32m%s\033[0m\n" "$*"; }
ylw()  { printf "\033[33m%s\033[0m\n" "$*"; }
blu()  { printf "\033[34m%s\033[0m\n" "$*"; }

# Check if we're in the right place
if [ ! -f "$PACKAGE_DIR/prompts/review.core.md" ]; then
  echo "Error: Cannot find review prompts. Expected location: $PACKAGE_DIR/prompts/"
  exit 1
fi

# Use PROJECT_ROOT if set, otherwise current directory
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
cd "$PROJECT_ROOT"

# Ensure Claude Code is in PATH if installed in non-standard location
if [ -x "$HOME/.claude/local/claude" ]; then
  export PATH="$HOME/.claude/local:$PATH"
fi

# Run auth check
bash "$PACKAGE_DIR/scripts/auth-check.sh" || exit 1

# Create workspace directories in project directory
mkdir -p "$PROJECT_ROOT/.review-pipeline/workspace/context" "$PROJECT_ROOT/.review-pipeline/workspace/reports"

# Load configuration using Node.js config loader
echo "Loading configuration..."
if ! node "$PACKAGE_DIR/lib/config-loader.js" validate >/dev/null 2>&1; then
  ylw "Warning: Configuration validation failed, using defaults"
fi

# Get test command from config or environment
TEST_CMD="${TEST_CMD:-$(node -e "
  import('$PACKAGE_DIR/lib/config-loader.js').then(async (module) => {
    const ConfigLoader = module.default;
    const loader = new ConfigLoader();
    await loader.load();
    console.log(loader.getTestCommand());
  }).catch(() => console.log('pytest tests/'));
" 2>/dev/null || echo 'pytest tests/')}"

# Check if parallel execution is enabled
PARALLEL_ENABLED=$(node -e "
  import('$PACKAGE_DIR/lib/config-loader.js').then(async (module) => {
    const ConfigLoader = module.default;
    const loader = new ConfigLoader();
    await loader.load();
    console.log(loader.config.execution?.parallel !== false);
  }).catch(() => console.log('true'));
" 2>/dev/null || echo 'true')

# Get enabled providers
ENABLED_PROVIDERS=$(node -e "
  import('$PACKAGE_DIR/lib/config-loader.js').then(async (module) => {
    const ConfigLoader = module.default;
    const loader = new ConfigLoader();
    await loader.load();
    console.log(loader.getEnabledProviders().join(' '));
  }).catch(() => console.log('claude codex gemini'));
" 2>/dev/null || echo 'claude codex gemini')

echo "Configuration:"
echo "  • Test command: $TEST_CMD"
echo "  • Parallel execution: $PARALLEL_ENABLED"
echo "  • Enabled providers: $ENABLED_PROVIDERS"
echo ""

# Build review context
echo "Building review context..."

# Get diff against default branch (from PROJECT_ROOT)
DEFAULT_BRANCH=$(cd "$PROJECT_ROOT" && git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
(cd "$PROJECT_ROOT" && git diff --patch "origin/$DEFAULT_BRANCH" > "$PROJECT_ROOT/.review-pipeline/workspace/context/diff.patch" 2>/dev/null) || \
  (cd "$PROJECT_ROOT" && git diff --patch HEAD~1 > "$PROJECT_ROOT/.review-pipeline/workspace/context/diff.patch" 2>/dev/null) || \
  echo "No diff available" > "$PROJECT_ROOT/.review-pipeline/workspace/context/diff.patch"

# Get changed files (from PROJECT_ROOT)
(cd "$PROJECT_ROOT" && git diff --name-only "origin/$DEFAULT_BRANCH" 2>/dev/null > "$PROJECT_ROOT/.review-pipeline/workspace/context/files.txt") || \
  (cd "$PROJECT_ROOT" && git diff --name-only HEAD~1 2>/dev/null > "$PROJECT_ROOT/.review-pipeline/workspace/context/files.txt") || \
  echo "No files changed" > "$PROJECT_ROOT/.review-pipeline/workspace/context/files.txt"

# Generate enhanced diff with line numbers
if [ -f "$PACKAGE_DIR/scripts/generate-enhanced-diff.js" ]; then
  node "$PACKAGE_DIR/scripts/generate-enhanced-diff.js" 2>/dev/null || echo "Failed to generate enhanced diff"
fi

# Generate PR context (works for both GitHub Actions and local)
bash "$PACKAGE_DIR/scripts/generate-pr-context.sh"

# Run tests if enabled
echo "Running tests..."
if [ -n "$TEST_CMD" ]; then
  # Check if enhanced test runner is available
  ENHANCED_RUNNER="$PACKAGE_DIR/scripts/run-tests-enhanced.sh"
  if [ -x "$ENHANCED_RUNNER" ]; then
    # Use enhanced runner that generates both text and JSON outputs
    echo "Using enhanced test runner for structured output..."
    set +e
    bash "$ENHANCED_RUNNER"
    TEST_EXIT_CODE=$?
    set -e
  else
    # Fallback to original implementation
    set +e
    echo "\$ $TEST_CMD" > "$PROJECT_ROOT/.review-pipeline/workspace/context/tests.txt"
    # Use sh -c to match workflow implementation (TODO: parse into array for safety)
    (cd "$PROJECT_ROOT" && timeout 300 sh -c "set -e; $TEST_CMD") >> "$PROJECT_ROOT/.review-pipeline/workspace/context/tests.txt" 2>&1
    TEST_EXIT_CODE=$?
    echo "== exit:$TEST_EXIT_CODE ==" >> "$PROJECT_ROOT/.review-pipeline/workspace/context/tests.txt"
    set -e
  fi
  
  if [ $TEST_EXIT_CODE -eq 0 ]; then
    grn "✓ Tests passed"
    # Show coverage if available
    if [ -f "$PROJECT_ROOT/.review-pipeline/workspace/context/test-summary.json" ]; then
      COVERAGE=$(jq -r '.coverage.percentage // "N/A"' "$PROJECT_ROOT/.review-pipeline/workspace/context/test-summary.json" 2>/dev/null || echo "N/A")
      if [ "$COVERAGE" != "N/A" ] && [ "$COVERAGE" != "null" ]; then
        echo "  Coverage: ${COVERAGE}%"
      fi
    fi
  else
    ylw "⚠ Tests failed with exit code $TEST_EXIT_CODE"
  fi
else
  echo "No test command configured" > "$PROJECT_ROOT/.review-pipeline/workspace/context/tests.txt"
fi

# Unset API key environment variables
unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY

# Run provider reviews
echo ""
if [ "$PARALLEL_ENABLED" = "true" ]; then
  blu "Running reviews in parallel for: $ENABLED_PROVIDERS"
else
  blu "Running reviews sequentially for: $ENABLED_PROVIDERS"
fi
echo ""

# Function to run a single provider
run_provider() {
  local provider="$1"
  local display_name="$2"
  
  echo "Starting $display_name review..."
  
  # Check if provider is enabled
  local enabled=$(node -e "
    import('$PACKAGE_DIR/lib/config-loader.js').then(async (module) => {
      const ConfigLoader = module.default;
      const loader = new ConfigLoader();
      await loader.load();
      console.log(loader.isProviderEnabled('$provider'));
    }).catch(() => console.log('true'));
  " 2>/dev/null || echo 'true')
  
  if [ "$enabled" != "true" ]; then
    ylw "  Skipping $display_name (disabled)"
    return 0
  fi
  
  # Get timeout from config
  local timeout=$(node -e "
    import('$PACKAGE_DIR/lib/config-loader.js').then(async (module) => {
      const ConfigLoader = module.default;
      const loader = new ConfigLoader();
      await loader.load();
      const config = loader.getProviderConfig('$provider');
      console.log(config.timeout);
    }).catch(() => console.log('120'));
  " 2>/dev/null || echo '120')
  
  # Run provider using secure execution script
  if bash "$PACKAGE_DIR/scripts/run-provider-review.sh" "$provider" "$timeout"; then
    grn "  ✓ $display_name review completed"
  else
    red "  ✗ $display_name review failed or timed out"
  fi
}

# Execute reviews based on configuration
if [ "$PARALLEL_ENABLED" = "true" ]; then
  # Run in parallel
  for provider in $ENABLED_PROVIDERS; do
    case "$provider" in
      claude) run_provider "claude" "Claude Code" & ;;
      codex)  run_provider "codex" "Codex CLI" & ;;
      gemini) run_provider "gemini" "Gemini CLI" & ;;
      *) ylw "Unknown provider: $provider" ;;
    esac
  done
  
  # Wait for all parallel jobs
  wait
else
  # Run sequentially
  for provider in $ENABLED_PROVIDERS; do
    case "$provider" in
      claude) run_provider "claude" "Claude Code" ;;
      codex)  run_provider "codex" "Codex CLI" ;;
      gemini) run_provider "gemini" "Gemini CLI" ;;
      *) ylw "Unknown provider: $provider" ;;
    esac
  done
fi

echo ""
grn "All reviews completed."

# Run aggregation
echo ""
echo "Aggregating results..."
cd "$PACKAGE_DIR" && npm install --no-audit --no-fund >/dev/null 2>&1
if node "$PACKAGE_DIR/scripts/aggregate-reviews.mjs"; then
  grn "✓ Aggregation successful"
else
  red "✗ Aggregation had issues"
fi

# Show results
echo ""
blu "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -f "$PROJECT_ROOT/.review-pipeline/workspace/gate.txt" ]; then
  gate_status=$(cat "$PROJECT_ROOT/.review-pipeline/workspace/gate.txt")
  if [ "$gate_status" = "pass" ]; then
    grn "  Gate: PASS ✓"
  else
    red "  Gate: FAIL ✗"
  fi
else
  ylw "  Gate: UNKNOWN"
fi
blu "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "See detailed results in:"
echo "  • $PROJECT_ROOT/.review-pipeline/workspace/summary.md"
echo "  • $PROJECT_ROOT/.review-pipeline/workspace/reports/*.json"
echo ""

# Show summary if it exists
if [ -f "$PROJECT_ROOT/.review-pipeline/workspace/summary.md" ]; then
  echo "Summary preview:"
  echo "────────────────"
  head -n 20 "$PROJECT_ROOT/.review-pipeline/workspace/summary.md"
  if [ $(wc -l < "$PROJECT_ROOT/.review-pipeline/workspace/summary.md") -gt 20 ]; then
    echo "... (truncated, see full summary in workspace/summary.md)"
  fi
fi
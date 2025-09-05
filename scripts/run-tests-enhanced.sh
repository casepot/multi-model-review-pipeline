#!/usr/bin/env bash
# Enhanced test runner that generates structured JSON outputs alongside plain text
# This preserves the existing tests.txt format while adding JSON context
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PACKAGE_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Use PROJECT_ROOT if set, otherwise current directory
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
WORKSPACE_DIR="$PROJECT_ROOT/.review-pipeline/workspace"
CONTEXT_DIR="$WORKSPACE_DIR/context"

# Get test command from environment or config
TEST_CMD="${TEST_CMD:-$(node -e "
  import('$PACKAGE_DIR/lib/config-loader.js').then(async (module) => {
    const ConfigLoader = module.default;
    const loader = new ConfigLoader();
    await loader.load();
    console.log(loader.getTestCommand());
  }).catch(() => console.log('uv run pytest -m unit'));
" 2>/dev/null || echo 'uv run pytest -m unit')}"

echo "Running enhanced test execution..."
echo "Test command: $TEST_CMD"

# Ensure output directory exists
mkdir -p "$CONTEXT_DIR"

# Run the original test command and capture output (preserving existing behavior)
echo "\$ $TEST_CMD" > "$CONTEXT_DIR/tests.txt"
set +e
(cd "$PROJECT_ROOT" && timeout 300 sh -c "set -e; $TEST_CMD") >> "$CONTEXT_DIR/tests.txt" 2>&1
TEST_EXIT_CODE=$?
echo "== exit:$TEST_EXIT_CODE ==" >> "$CONTEXT_DIR/tests.txt"
set -e

# Now run the same tests with structured output (non-breaking enhancement)
echo "Generating structured test data..."

# Run with JUnit XML output
set +e
(cd "$PROJECT_ROOT" && timeout 300 sh -c "set -e; $TEST_CMD --junit-xml=$CONTEXT_DIR/test-results.xml --cov-report=json:$CONTEXT_DIR/coverage.json -q") >/dev/null 2>&1
ENHANCED_EXIT_CODE=$?
set -e

# Generate test summary JSON
if [ -f "$CONTEXT_DIR/test-results.xml" ]; then
  # Convert JUnit XML to JSON summary
  python3 "$SCRIPT_DIR/generate-test-summary.py" \
    "$CONTEXT_DIR/test-results.xml" \
    "$CONTEXT_DIR/coverage.json" \
    "$CONTEXT_DIR/test-summary.json" 2>/dev/null || {
    echo "Warning: Could not generate test summary JSON"
  }
fi

# Create a basic metadata file with test execution info
cat > "$CONTEXT_DIR/test-metadata.json" <<EOF
{
  "command": "$TEST_CMD",
  "exit_code": $TEST_EXIT_CODE,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "working_directory": "$PROJECT_ROOT",
  "timeout_seconds": 300,
  "enhanced_outputs_generated": $([ -f "$CONTEXT_DIR/test-summary.json" ] && echo "true" || echo "false")
}
EOF

# Return the original test exit code
exit $TEST_EXIT_CODE
# Multi-Model Review Pipeline

(Human Note: This is a quick and dirty way to get PR reviews done automatically by the three major private provider's CLI programs using a subscription rather than API keys, to take advantage of their generous limits before they inevitably restrict usage down the line when funds dry up. Codex and Gemini were simple to integrate with GH actions, Claude was more annoying and required a keychain workaround and local github runner which is a security liability. For the next iteration of this I would simplify and limit this to the review-local.sh script, and go from there. JSON output and parsing was a brittle point as well, as each provider has different ways of providing structured output and even then this fails maybe 1/5 times for Claude and Gemini. I would also re look at configuration and surface the context packet configuration, allowing devs to create scripts that would build artifacts for the context packet, perhaps following some schema or rules etc.) 

A powerful, provider-agnostic code review pipeline that orchestrates multiple AI models (Claude, Codex, Gemini) to provide comprehensive PR reviews. Designed for self-hosted runners with local authentication.

## Features

- **Multi-Model Support**: Run reviews using Claude Code, Codex CLI, and Gemini CLI in parallel or sequentially
- **Flexible Configuration**: Layer-based configuration system with defaults, project overrides, and environment variables
- **Security-First**: OAuth/Keychain authentication only - no API keys in code or environment
- **Structured Output**: Consistent JSON reports with schema validation
- **Smart Gating**: Configurable severity thresholds and must-fix detection
- **GitHub Integration**: Native GitHub Actions support with PR commenting
- **CLI & Programmatic APIs**: Use as npm package, CLI tool, or GitHub Action

## Installation

### As npm Package

```bash
npm install --save-dev @multi-model/review-pipeline
```

### As Global CLI

```bash
npm install -g @multi-model/review-pipeline
```

### As GitHub Action

```yaml
- uses: multi-model/review-pipeline-action@v1
```

## Quick Start

### 1. Install Provider CLIs

The pipeline requires the AI provider CLIs to be installed and authenticated:

```bash
# Claude Code
curl -fsSL https://claude.ai/install | sh
claude /login

# Codex CLI
npm install -g codex-cli
codex auth login

# Gemini CLI
pip install gemini-cli
gemini auth login
```

### 2. Create Configuration

Create `.reviewrc.json` in your project root:

```json
{
  "providers": {
    "claude": { "enabled": true, "model": "opus" },
    "codex": { "enabled": true, "model": "gpt-5" },
    "gemini": { "enabled": false }
  },
  "testing": {
    "enabled": true,
    "command": "npm test"
  },
  "gating": {
    "enabled": true,
    "must_fix_threshold": 1
  }
}
```

### 3. Run Review

```bash
# Using npx (if installed as dev dependency)
npx review-pipeline run

# Using global CLI
review-pipeline run --providers claude,gemini --test-cmd "pytest tests/"

# Using npm script
npm run review
```

## CLI Usage

```bash
review-pipeline <command> [options]

Commands:
  run              Run the review pipeline
  auth-check       Check authentication status for all providers
  validate         Validate configuration
  show-config      Show resolved configuration
  build-command    Build provider command (debugging)

Options:
  -c, --config <path>       Configuration file path (default: .reviewrc.json)
  -p, --providers <list>    Comma-separated provider list
  -t, --test-cmd <cmd>      Test command to run
  --parallel/--no-parallel  Run providers in parallel
  --timeout <seconds>       Global timeout (default: 600)
  --project-root <path>     Project root directory
  --verbose                 Enable verbose output
```

## Programmatic API

```javascript
import { ReviewPipeline } from '@multi-model/review-pipeline';

const pipeline = new ReviewPipeline({
  projectRoot: process.cwd(),
  configFile: '.reviewrc.json',
  providers: ['claude', 'codex'],
  parallel: true,
  timeout: 600
});

const results = await pipeline.run();
console.log(results.summary);
```

## GitHub Actions Integration

### Basic Workflow

```yaml
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  review:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          
      - uses: multi-model/review-pipeline-action@v1
        with:
          config-file: .reviewrc.json
          test-command: ${{ vars.TEST_CMD }}
```

### Advanced Configuration

```yaml
- uses: multi-model/review-pipeline-action@v1
  with:
    providers: claude,codex,gemini
    parallel: true
    timeout: 900
    test-command: npm test && npm run lint
    fail-on-must-fix: true
    comment-on-pr: true
    artifact-reports: true
```

## Configuration

### Configuration Layers (Priority Order)

1. **Runtime flags** (CLI arguments, action inputs)
2. **Environment variables** (see mapping below)
3. **Project config** (`.reviewrc.json`)
4. **Pipeline defaults** (built-in)

### Environment Variable Mapping

```bash
# Global settings
TEST_CMD="pytest tests/"           # Test command
REVIEW_TIMEOUT="600"               # Global timeout (seconds)
REVIEW_PARALLEL="true"             # Parallel execution

# Provider settings
CLAUDE_MODEL="opus"                # Claude model
CODEX_REASONING="high"             # Codex reasoning level
GEMINI_MODEL="gemini-2.5-pro"      # Gemini model

# Feature flags
ENABLED_PROVIDERS="claude,gemini"  # Active providers
```

### Full Configuration Schema

```json
{
  "execution": {
    "parallel": true,
    "timeout_seconds": 600,
    "fail_fast": false
  },
  "providers": {
    "claude": {
      "enabled": true,
      "model": "opus",
      "timeout_override": null,
      "flags": {
        "permission_mode": "default",
        "output_format": "json"
      }
    },
    "codex": {
      "enabled": true,
      "model": "gpt-5",
      "reasoning_effort": "high",
      "sandbox_mode": "read-only"
    },
    "gemini": {
      "enabled": true,
      "model": "gemini-2.5-pro",
      "flags": {
        "all_files": true
      }
    }
  },
  "review": {
    "include_patterns": ["**/*"],
    "exclude_patterns": ["**/node_modules/**"],
    "max_diff_size_kb": 500,
    "max_files": 100
  },
  "gating": {
    "enabled": true,
    "must_fix_threshold": 1,
    "block_on_test_failure": true,
    "severity_thresholds": {
      "critical": 0,
      "high": 0,
      "medium": 5,
      "low": 10
    }
  },
  "testing": {
    "enabled": true,
    "command": "./run-tests.sh",
    "timeout_seconds": 300,
    "required_pass_rate": 0.95
  }
}
```

## Project-Specific Criteria

Add custom review criteria in `.review-criteria.md`:

```markdown
# Project Review Criteria

<performance>
- Ensure all database queries use indexes
- Avoid N+1 query patterns
- Cache expensive computations
</performance>

<security>
- Validate all user inputs
- Use parameterized queries
- Never log sensitive data
</security>

<code-style>
- Follow project naming conventions
- Add JSDoc comments for public APIs
- Keep functions under 50 lines
</code-style>
```

## Authentication

The pipeline uses **subscription-based authentication only**. No API keys are stored or transmitted.

### Required Authentication Methods

- **Claude**: OAuth via `/login` command (stored in Keychain)
- **Codex**: OAuth via `auth login` command
- **Gemini**: OAuth via `auth login` command

### Verify Authentication

```bash
review-pipeline auth-check
```

## Output

### Report Structure

```
workspace/
├── context/               # Input context
│   ├── diff.patch        # Git diff
│   ├── files.txt         # Changed files
│   ├── tests.txt         # Test results
│   └── pr.json           # PR metadata
├── reports/              # Provider outputs
│   ├── claude-code.json  # Claude report
│   ├── codex-cli.json    # Codex report
│   └── gemini-cli.json   # Gemini report
├── summary.md            # Aggregated summary
└── gate.txt              # Pass/fail decision
```

### Report Schema

Each provider report follows this structure:

```json
{
  "provider": "claude",
  "model": "opus",
  "timestamp": "2024-01-01T00:00:00Z",
  "issues": [
    {
      "severity": "high",
      "category": "security",
      "file": "src/auth.js",
      "line": 42,
      "message": "SQL injection vulnerability",
      "suggestion": "Use parameterized queries",
      "must_fix": true
    }
  ],
  "summary": {
    "total_issues": 5,
    "must_fix_count": 1,
    "by_severity": {
      "critical": 0,
      "high": 1,
      "medium": 2,
      "low": 2
    }
  },
  "execution": {
    "duration_seconds": 45,
    "success": true
  }
}
```

## Development

### Running Tests

```bash
npm test              # Run all tests
npm run test:watch    # Watch mode
npm run test:coverage # Coverage report
```

### Local Development

```bash
# Clone and setup
git clone https://github.com/multi-model/review-pipeline.git
cd review-pipeline
npm install

# Run locally
PROJECT_ROOT=/path/to/test/repo npm run review

# Test CLI
./bin/review-pipeline auth-check
```

## Troubleshooting

### Common Issues

1. **"Provider not authenticated"**
   - Run `review-pipeline auth-check`
   - Re-authenticate with provider's login command

2. **"Command not found: claude"**
   - Ensure provider CLI is installed
   - Check PATH includes installation directory

3. **"No diff available"**
   - Ensure git repository has commits
   - Check you're not on the default branch

4. **"Timeout exceeded"**
   - Increase timeout in configuration
   - Check provider service status

### Debug Mode

```bash
# Enable verbose output
review-pipeline run --verbose

# Check resolved configuration
review-pipeline show-config

# Build command without executing
review-pipeline build-command claude
```

## Security

- **No API Keys**: Uses OAuth/subscription authentication only
- **Input Validation**: All inputs sanitized and validated
- **Schema Validation**: JSON schemas enforce structure
- **Path Traversal Protection**: Prevents directory escape
- **Command Injection Prevention**: Uses spawn() not exec()

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Support

- **Issues**: [GitHub Issues](https://github.com/multi-model/review-pipeline/issues)
- **Discussions**: [GitHub Discussions](https://github.com/multi-model/review-pipeline/discussions)
- **Security**: Report vulnerabilities via GitHub Security Advisories

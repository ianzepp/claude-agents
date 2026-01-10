# Claude Agents

Specialized diagnostic agents for Claude Code. Each agent has a focused role with clear constraints—analysts report findings, fixers make targeted changes.

## Design Philosophy

**Separation of diagnosis from action.** Read-only agents (augur, columbo, galen) analyze and report. Active agents (titus, cato) make changes within strict guardrails. This split prevents premature fixes and enables better review workflows.

**Time-boxed pragmatism.** Agents work within resource constraints—they're not exhaustive auditors. When uncertain, they escalate rather than guess.

**Mode-controlled behavior.** The `--mode` flag determines what happens after analysis: output a report, make changes, or create GitHub issues.

## Agents

### augur
**Forward-consequence analyst.** Traces what will break *when* changes are made.

Use for: Impact analysis on proposed changes, design reviews, refactoring plans

```bash
agent augur "analyze impact of switching from JWT to sessions"
agent augur --mode issue "what breaks if we remove the cache layer?"
```

### columbo
**Root-cause investigator.** Traces failures *backward* from symptom to source.

Use for: Debugging production issues, understanding test failures, analyzing error reports

```bash
agent columbo "why does the login test fail on CI?"
agent columbo --mode update "investigate and document the memory leak"
```

### galen
**Test diagnostician.** Classifies test failures (CODE BUG vs TEST BUG vs FIXTURE BUG vs ENVIRONMENT).

Use for: Triaging test suite failures, understanding CI breakage

```bash
agent galen "diagnose all failing tests in the auth module"
agent galen --mode issue "classify test failures and create issues"
```

### titus
**TypeScript error fixer.** Resolves type errors by fixing root causes, never suppressions.

Hard constraints: No `as any`, no `@ts-ignore`, no deleting code to silence errors. Escalates when proper fixes require design decisions.

Use for: Cleaning up type errors after refactoring, fixing inference issues

```bash
agent titus --mode update "fix all type errors in src/api/"
agent titus "analyze type errors and recommend fixes"
```

### cato
**Pragmatic PR reviewer.** Makes accept/reject decisions without deep research.

Time-boxed to 5 minutes. Three verdicts: APPROVE, REQUEST CHANGES, or NEEDS FURTHER REVIEW. Focuses on security, correctness, breaking changes, tests, and egregious quality issues.

Use for: First-pass PR review, gate-checking before human review

```bash
agent cato --mode update "review PR #42"
agent cato --dispatch --mode update "review PR #123"  # remote execution
```

### diogenes
**Free-spirit explorer.** Roams codebases with fresh eyes and suggests 2-3 unexpected improvements.

Unconstrained blue-sky thinking. Examines code, architecture, git history, issues, PRs—anything that catches attention. Questions assumptions, identifies opportunities others miss.

Use for: Fresh perspective on mature projects, finding hidden technical debt, discovering simplification opportunities

```bash
agent diogenes "explore this project and suggest improvements"
agent diogenes --mode issue "find 2-3 things worth changing"
agent diogenes --dispatch "what would you do differently here?"
```

### claude
**Pass-through.** Vanilla Claude with no special constraints. Use for ad-hoc tasks.

```bash
agent claude "explain how the authentication flow works"
```

## Usage

```bash
agent <name> [options] <goal>
```

### Options

- `-m, --model <model>` — Model to use (default: sonnet)
- `-d, --dir <path>` — Working directory (default: cwd)
- `--mode <mode>` — Action mode: read (default), update, issue
- `--dispatch` — Run on remote worker (requires git repo)
- `-w, --worker <id>` — Specific worker for dispatch (optional)
- `-n, --dry-run` — Show prompt without executing
- `-h, --help` — Show help

### Modes

**read (default)** — Analyze and output report to stdout. No modifications.

```bash
agent columbo "why does the build fail?"
```

**update** — Make changes directly after analysis (fix issues, update docs).

```bash
agent titus --mode update "fix type errors"
agent cato --mode update "review PR #42"
```

**issue** — Create GitHub issues for each finding.

```bash
agent augur --mode issue "analyze impact of removing user.email field"
agent galen --mode issue "classify test failures"
```

## Remote Execution

Use `--dispatch` to run agents on remote workers via [claude-workers](https://github.com/ianzepp/claude-workers). Workers provide:

- **Git isolation**: Checkout PR branches without affecting local state
- **Clean environment**: Run builds/tests in sandboxed workers
- **Parallel execution**: Multiple agents work simultaneously on different branches

Remote execution requires a git repository (detects repo from `.git/config`).

```bash
# Review a PR remotely (can checkout the PR branch)
cd ~/github/owner/repo
agent cato --dispatch --mode update "review PR #42"

# Run diagnostic on a specific branch
agent columbo --dispatch "investigate test failures on feature-x branch"

# Use opus for complex analysis
agent augur --dispatch -m opus "analyze architectural impact"

# Specify a worker
agent galen --dispatch -w 03 "diagnose test failures"
```

See [claude-workers](https://github.com/ianzepp/claude-workers) for worker setup and management.

## Examples

### Diagnose and fix

```bash
# Step 1: Diagnose (read-only)
agent columbo "why does test X fail?"

# Step 2: Review findings, then fix
agent titus --mode update "fix the type errors identified in columbo report"
```

### Impact analysis with issue creation

```bash
agent augur --mode issue "what breaks if we change the API response format?"
# Creates GitHub issues for each identified impact area
```

### PR review workflow

```bash
# First-pass review
agent cato --dispatch --mode update "review PR #42"

# If verdict is NEEDS FURTHER REVIEW, deep dive
agent columbo --dispatch "investigate the auth flow changes in PR #42"
```

### Test failure triage

```bash
# Classify failures
agent galen --mode issue "diagnose all test failures"

# Fix code bugs (not test bugs)
agent titus --mode update "fix code bugs identified by galen"
```

## Adding New Agents

Create `{name}.md` with YAML frontmatter:

```markdown
---
name: your-agent
description: One-line description
model: sonnet
---

You are [role description]. Your job is to [specific task].

## Hard Constraints

**[Key limitation].** [Explanation of what's forbidden/required]

...
```

Agents should:
- Have clear, focused roles
- Define hard constraints upfront
- Specify allowed/forbidden actions
- Include output format examples
- State principles/decision criteria

## Installation

Clone and add to PATH:

```bash
git clone https://github.com/ianzepp/claude-agents.git
export PATH="$PATH:/path/to/claude-agents"
```

Or symlink into your bin:

```bash
ln -s /path/to/claude-agents/agent.sh /usr/local/bin/agent
```

Requires:
- [Claude Code](https://claude.com/claude-code) CLI
- `gh` (GitHub CLI) for issue mode
- [claude-workers](https://github.com/ianzepp/claude-workers) for `--dispatch` (optional)

## Project Structure

```
claude-agents/
  agent.sh          # Launcher script
  augur.md          # Forward-consequence analyst
  cato.md           # PR reviewer
  claude.md         # Pass-through (no constraints)
  columbo.md        # Root-cause investigator
  diogenes.md       # Free-spirit explorer
  galen.md          # Test diagnostician
  titus.md          # TypeScript fixer
```

## License

MIT

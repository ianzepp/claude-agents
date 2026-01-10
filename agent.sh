#!/usr/bin/env bash
set -euo pipefail

# Unset session-specific API key so claude uses CLAUDE_CODE_OAUTH_TOKEN
unset ANTHROPIC_API_KEY

# Resolve symlinks to find actual script location
SCRIPT="$0"
while [[ -L "$SCRIPT" ]]; do
  SCRIPT="$(readlink "$SCRIPT")"
done
AGENTS_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
MODEL="sonnet"
WORK_DIR="$(pwd)"
AGENT=""
AGENT_FILE=""
GOAL=""
MODE="read"
DISPATCH=false
WORKER=""
DRY_RUN=false

usage() {
  cat <<EOF
Usage: agent <name> [options] <goal>
       agent --agent <path> [options] <goal>
       agent <name> [options] < goal.txt

Options:
  -a, --agent <path>      Use agent prompt from file path
  -m, --model <model>     Model to use (default: sonnet)
  -d, --dir <path>        Working directory (default: cwd)
      --mode <mode>       Action mode: read (default), update, issue
      --dispatch          Run agent on remote worker (via cw dispatch)
  -w, --worker <id>       Specific worker to use (with --dispatch)
  -n, --dry-run           Show prompt without running claude
  -h, --help              Show this help

Modes:
  read      Analyze and output report to stdout (default)
  update    Make changes directly (fix issues, update documents)
  issue     Create GitHub issues for findings

Remote Execution:
  --dispatch runs the agent on a remote worker via claude-workers.
  Useful for agents that need to checkout branches, run builds, etc.
  Detects repo from working directory (.git/config)

Available agents:
EOF
  for f in "$AGENTS_DIR"/*.md; do
    name=$(basename "$f" .md)
    # Skip documentation files (all caps)
    [[ "$name" =~ ^[A-Z]+$ ]] && continue
    [[ -f "$f" ]] && echo "  $name"
  done
  exit 0
}

[[ $# -eq 0 ]] && usage
[[ "$1" == "-h" || "$1" == "--help" ]] && usage

# First arg is agent name unless it's an option
if [[ "$1" != -* ]]; then
  AGENT="$1"; shift
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--agent)   AGENT_FILE="$2"; shift 2 ;;
    -m|--model)   MODEL="$2"; shift 2 ;;
    -d|--dir)     WORK_DIR="$2"; shift 2 ;;
    --mode)       MODE="$2"; shift 2 ;;
    --dispatch)   DISPATCH=true; shift ;;
    -w|--worker)  WORKER="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -h|--help)    usage ;;
    --)           shift; GOAL="$*"; break ;;
    -*)           echo "Unknown option: $1" >&2; exit 1 ;;
    *)            GOAL="$1"; shift ;;
  esac
done

# Read goal from stdin if not provided
if [[ -z "$GOAL" ]] && [[ ! -t 0 ]]; then
  GOAL="$(cat)"
fi

if [[ -z "$GOAL" ]]; then
  echo "Error: No goal provided" >&2
  exit 1
fi

# Validate mode
case "$MODE" in
  read|update|issue) ;;
  *)
    echo "Error: Invalid mode: $MODE" >&2
    echo "Valid modes: read, update, issue" >&2
    exit 1
    ;;
esac

# Resolve agent file
if [[ -n "$AGENT_FILE" ]]; then
  # --agent provided: use path directly
  if [[ ! -f "$AGENT_FILE" ]]; then
    echo "Error: Agent file not found: $AGENT_FILE" >&2
    exit 1
  fi
  AGENT="$(basename "$AGENT_FILE" .md)"
elif [[ -n "$AGENT" ]]; then
  # Agent name provided: look in agents directory
  AGENT_FILE="$AGENTS_DIR/${AGENT}.md"
  if [[ ! -f "$AGENT_FILE" ]]; then
    echo "Error: Agent not found: $AGENT" >&2
    echo "Available: $(ls "$AGENTS_DIR"/*.md 2>/dev/null | xargs -n1 basename | sed 's/\.md$//' | tr '\n' ' ')" >&2
    exit 1
  fi
else
  echo "Error: No agent specified" >&2
  echo "Usage: agent <name> <goal> OR agent --agent <path> <goal>" >&2
  exit 1
fi

# Extract prompt (skip YAML frontmatter if present)
if head -1 "$AGENT_FILE" | grep -q '^---$'; then
  PROMPT="$(awk '/^---$/{n++;next} n>=2' "$AGENT_FILE")"
else
  PROMPT="$(cat "$AGENT_FILE")"
fi

cd "$WORK_DIR" || exit 1

# Build mode-specific instructions
MODE_INSTRUCTIONS=""
case "$MODE" in
  read)
    MODE_INSTRUCTIONS="<instructions>
Mode: read

Analyze and report your findings to stdout. Do not modify any files or create issues.
Your output will be read by a human who will decide what action to take.
</instructions>"
    ;;
  update)
    MODE_INSTRUCTIONS="<instructions>
Mode: update

After completing your analysis, make the necessary changes directly:
- Fix issues you identify (if you have editing capabilities)
- Update documents that need correction
- Apply fixes that follow clearly from your analysis

Use your normal editing tools. Commit changes with clear messages if appropriate.
</instructions>"
    ;;
  issue)
    MODE_INSTRUCTIONS="<instructions>
Mode: issue

After completing your analysis, create GitHub issues for your findings:
1. Detect the repository from the working directory (look for .git/config or use 'git remote get-url origin')
2. For each distinct problem/recommendation, create a separate issue using 'gh issue create'
3. Use clear, actionable titles
4. Include relevant context: file paths, line numbers, error messages, code snippets
5. Label appropriately if the issue type is clear (bug, enhancement, documentation, etc.)
6. Reference this analysis in the issue body

Format each issue clearly:
- Title: Concise problem statement (e.g., 'Type error in authentication module', 'Missing test coverage for user validation')
- Body: Your analysis for this specific issue, what needs to be done, and why

After creating issues, output a summary showing the issue numbers and titles.
</instructions>"
    ;;
esac

FULL_PROMPT="${PROMPT}

${MODE_INSTRUCTIONS}

---

Working Directory: ${WORK_DIR}

Goal: ${GOAL}"

if [[ "$DRY_RUN" == true ]]; then
  echo "Agent: $AGENT"
  echo "Model: $MODEL"
  echo "Mode: $MODE"
  echo "Dispatch: $DISPATCH"
  [[ -n "$WORKER" ]] && echo "Worker: $WORKER"
  echo "Directory: $WORK_DIR"

  if [[ "$DISPATCH" == true ]]; then
    # Try to detect repo for dry-run display
    cd "$WORK_DIR" 2>/dev/null || true
    if [[ -d .git ]]; then
      REPO=$(git config --get remote.origin.url 2>/dev/null | sed -E 's|^https://github.com/||; s|^git@github.com:||; s|\.git$||' || echo "<repo>")
      echo "Repository: $REPO"
      echo -n "Command: cw dispatch -r $REPO -m $MODEL"
      [[ -n "$WORKER" ]] && echo -n " -w $WORKER"
      echo " -p ..."
    else
      echo "Command: cw dispatch -r <repo> -m $MODEL -p ..."
    fi
  else
    echo "Command: claude --model $MODEL -p ..."
  fi

  echo ""
  echo "=== PROMPT ==="
  echo "$FULL_PROMPT"
  exit 0
fi

if [[ "$DISPATCH" == true ]]; then
  # Detect repository from git config
  cd "$WORK_DIR" || exit 1
  if [[ ! -d .git ]]; then
    echo "Error: --dispatch requires a git repository (no .git directory in $WORK_DIR)" >&2
    exit 1
  fi

  REPO=$(git config --get remote.origin.url | sed -E 's|^https://github.com/||; s|^git@github.com:||; s|\.git$||')
  if [[ -z "$REPO" ]]; then
    echo "Error: Could not detect repository from git remote" >&2
    exit 1
  fi

  # Build cw dispatch command
  CW_ARGS=("-r" "$REPO" "-m" "$MODEL")
  [[ -n "$WORKER" ]] && CW_ARGS+=("-w" "$WORKER")

  echo "Dispatching to remote worker..."
  echo "  Repository: $REPO"
  echo "  Agent: $AGENT"
  echo "  Mode: $MODE"
  echo "  Model: $MODEL"
  [[ -n "$WORKER" ]] && echo "  Worker: $WORKER"

  # Pass prompt via stdin
  exec cw dispatch "${CW_ARGS[@]}" -p "$FULL_PROMPT"
else
  # Run locally
  exec claude --model "$MODEL" -p "$FULL_PROMPT"
fi

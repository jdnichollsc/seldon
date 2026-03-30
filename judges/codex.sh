#!/usr/bin/env bash
# Seldon judge-runner for OpenAI Codex CLI
# Prerequisites: npm install -g @openai/codex
#
# Activate by copying to the skill root:
#   cp judges/codex.sh judge-runner.sh

set -euo pipefail

# --- Config (override via environment) ---
JUDGE_MODEL="${JUDGE_MODEL:-gpt-5.4}"
JUDGE_REASONING="${JUDGE_REASONING:-xhigh}"
JUDGE_WEB_SEARCH="${JUDGE_WEB_SEARCH:-cached}"

# --- Argument parsing ---
usage() {
  echo "Usage: $0 [--focus balanced|architecture|evaluation|product|operations|safety] <plan-file> [supporting-file ...]" >&2
  exit "${1:-1}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
schema_path="$script_dir/seldon.schema.json"
[[ -f "$schema_path" ]] || schema_path="$script_dir/../seldon.schema.json"
focus="balanced"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --focus)
      [[ $# -lt 2 ]] && { echo "Missing value for --focus" >&2; usage; }
      focus="$2"; shift 2 ;;
    --help|-h) usage 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

[[ $# -lt 1 ]] && usage

case "$focus" in
  balanced|architecture|evaluation|product|operations|safety) ;;
  *) echo "Unsupported focus: $focus" >&2; usage ;;
esac

# --- Workspace root ---
workspace_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"

# --- Resolve paths relative to workspace ---
resolve_path() {
  local input="$1"
  local abs_dir abs_path
  abs_dir="$(cd "$(dirname "$input")" && pwd -P)"
  abs_path="$abs_dir/$(basename "$input")"
  [[ -f "$abs_path" ]] || { echo "Missing file: $input" >&2; exit 1; }
  case "$abs_path" in
    "$workspace_root"/*) printf '%s\n' "${abs_path#$workspace_root/}" ;;
    *) echo "File must live inside the workspace: $input" >&2; exit 1 ;;
  esac
}

primary_plan="$(resolve_path "$1")"; shift

supporting_files=()
for path in "$@"; do
  supporting_files+=("$(resolve_path "$path")")
done

# --- Build supporting block ---
if [[ ${#supporting_files[@]} -gt 0 ]]; then
  supporting_block=""
  for path in "${supporting_files[@]}"; do
    supporting_block+="- ${path}"$'\n'
  done
  supporting_block="${supporting_block%$'\n'}"
else
  supporting_block="- (none provided; inspect nearby workspace context as needed)"
fi

# --- Focus instructions ---
case "$focus" in
  architecture) focus_inst='- Emphasize architecture and implementation realism.\n- Be especially strict about service boundaries, dependency sprawl, migration risk, and hidden integration work.' ;;
  evaluation)   focus_inst='- Emphasize evaluation rigor and observability.\n- Be especially strict about measurable success criteria, regression detection, and testability of quality claims.' ;;
  product)      focus_inst='- Emphasize product risk and delivery quality.\n- Be especially strict about user-visible failure modes, sequencing, and scope realism.' ;;
  operations)   focus_inst='- Emphasize rollout and operational durability.\n- Be especially strict about ownership, alerting, rollback, failure handling, and maintenance burden.' ;;
  safety)       focus_inst='- Emphasize safety, privacy, and security.\n- Be especially strict about hallucination controls, citation integrity, access assumptions, and unsafe fallback behavior.' ;;
  *)            focus_inst='- Keep the review balanced across repo fit, correctness, sequencing, evaluation, operations, and safety.\n- Prioritize concrete evidence from the current workspace over speculation.' ;;
esac

# --- Build prompt ---
prompt_file="$(mktemp)"
output_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "$prompt_file" "$output_file" "$stderr_file"' EXIT

cat <<EOF > "$prompt_file"
You are evaluating a plan written by another LLM, usually Claude Code.

Primary plan:
- ${primary_plan}

Supporting files:
${supporting_block}

Task:
- Read the primary plan first.
- Inspect only the workspace files needed to verify whether the plan fits this codebase and whether its key claims are supported.
- Judge the plan as an independent reviewer, not as a co-author.
- Prefer concrete, high-signal findings over a rewrite.
- Treat unsupported assumptions, missing prerequisites, broken sequencing, and conflicts with workspace reality as valid findings.
- Review focus: ${focus}

Rubric:
- repo fit: does the proposal match this workspace's code, docs, and current state?
- technical correctness: are the architecture, APIs, data flows, and dependencies coherent?
- scope and sequencing: are prerequisites and rollout steps realistic?
- evaluation: are metrics, tests, and observability adequate for the proposed change?
- safety and operations: are privacy, security, failure modes, and rollback handled where relevant?

Focus instructions:
$(echo -e "$focus_inst")

Output requirements:
- Return JSON matching the provided schema.
- Use blocking_findings only for issues that materially threaten correctness, feasibility, safety, or delivery.
- Use file references like path:line in the references arrays whenever possible.
- If a time-sensitive or external claim cannot be verified locally, say that explicitly in evidence rather than pretending it is confirmed.
- If the plan is solid, return empty findings arrays and an approve-style verdict.
EOF

# --- Run Codex ---
if ! codex exec \
  -C "$workspace_root" \
  -m "$JUDGE_MODEL" \
  -c "model_reasoning_effort=\"$JUDGE_REASONING\"" \
  -c "approval_policy=\"never\"" \
  -c "web_search=\"$JUDGE_WEB_SEARCH\"" \
  -s read-only \
  --output-schema "$schema_path" \
  --output-last-message "$output_file" \
  - < "$prompt_file" > /dev/null 2> "$stderr_file"; then
  cat "$stderr_file" >&2
  exit 1
fi

if [[ ! -s "$output_file" ]]; then
  cat "$stderr_file" >&2
  echo "Codex did not return a final message." >&2
  exit 1
fi

cat "$output_file"

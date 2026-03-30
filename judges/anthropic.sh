#!/usr/bin/env bash
# Seldon judge-runner for Anthropic Claude API (via curl)
# Prerequisites: ANTHROPIC_API_KEY environment variable
#
# Gives you a second-opinion review from a separate Claude instance,
# useful when you want model diversity but stay in the Anthropic ecosystem.
#
# Activate by copying to the skill root:
#   cp judges/anthropic.sh judge-runner.sh

set -euo pipefail

# --- Config (override via environment) ---
JUDGE_MODEL="${JUDGE_MODEL:-claude-sonnet-4-6-20250514}"

# --- Argument parsing ---
usage() {
  echo "Usage: $0 [--focus balanced|architecture|evaluation|product|operations|safety] <plan-file> [supporting-file ...]" >&2
  exit "${1:-1}"
}

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

[[ -z "${ANTHROPIC_API_KEY:-}" ]] && { echo "ANTHROPIC_API_KEY is not set" >&2; exit 1; }

# --- Read plan file ---
primary_plan="$1"; shift
[[ -f "$primary_plan" ]] || { echo "Missing file: $primary_plan" >&2; exit 1; }
plan_content="$(cat "$primary_plan")"

supporting_content=""
for path in "$@"; do
  [[ -f "$path" ]] || { echo "Missing file: $path" >&2; exit 1; }
  supporting_content+="--- $path ---"$'\n'"$(cat "$path")"$'\n\n'
done

# --- Focus instructions ---
case "$focus" in
  architecture) focus_inst="Emphasize architecture and implementation realism. Be strict about service boundaries, dependency sprawl, migration risk." ;;
  evaluation)   focus_inst="Emphasize evaluation rigor and observability. Be strict about measurable success criteria and testability." ;;
  product)      focus_inst="Emphasize product risk and delivery quality. Be strict about user-visible failure modes and scope realism." ;;
  operations)   focus_inst="Emphasize rollout and operational durability. Be strict about ownership, alerting, rollback, and maintenance." ;;
  safety)       focus_inst="Emphasize safety, privacy, and security. Be strict about hallucination controls and access assumptions." ;;
  *)            focus_inst="Keep the review balanced across all dimensions. Prioritize concrete evidence over speculation." ;;
esac

# --- Read schema ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
schema_path="$script_dir/../seldon.schema.json"
[[ -f "$schema_path" ]] || schema_path="$script_dir/seldon.schema.json"
schema="$(cat "$schema_path")"

# --- Build request ---
system_prompt="You are an independent plan reviewer. Evaluate the plan against the codebase. Return ONLY valid JSON matching the provided schema — no markdown, no wrapping. Focus: $focus. $focus_inst"

user_prompt="Plan file ($primary_plan):
$plan_content

${supporting_content:+Supporting files:
$supporting_content}

Output schema:
$schema"

# Escape for JSON
system_escaped="$(printf '%s' "$system_prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
user_escaped="$(printf '%s' "$user_prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"

response="$(curl -s https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d "{
    \"model\": \"$JUDGE_MODEL\",
    \"max_tokens\": 4096,
    \"system\": $system_escaped,
    \"messages\": [
      {\"role\": \"user\", \"content\": $user_escaped}
    ]
  }")"

# Extract content
content="$(echo "$response" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["content"][0]["text"])' 2>/dev/null)" || {
  echo "Failed to parse Anthropic response:" >&2
  echo "$response" >&2
  exit 1
}

echo "$content"

#!/usr/bin/env bash
# Maps action inputs (GHL_* env vars) to a gh-labeler CLI invocation, captures
# the --json envelope, and republishes it as step outputs and a job summary.
set -euo pipefail

command="${GHL_COMMAND:-sync}"
case "$command" in
  validate | plan | sync) ;;
  *)
    echo "::error::Invalid command '${command}'. Expected one of: validate, plan, sync."
    exit 2
    ;;
esac

args=("$command")

if [[ "$command" == "validate" ]]; then
  # validate is offline: it takes only a config path, so surface any inputs
  # that would silently do nothing.
  ignored=()
  [[ -n "${GHL_REPOSITORY:-}" ]] && ignored+=(repository)
  [[ -n "${GHL_FROM:-}" ]] && ignored+=(from)
  [[ -n "${GHL_PRUNE:-}" ]] && ignored+=(prune)
  [[ "${GHL_SIMILARITY:-true}" == "false" ]] && ignored+=(similarity)
  [[ "${GHL_DRY_RUN:-false}" == "true" ]] && ignored+=(dry-run)
  [[ "${GHL_CHECK:-false}" == "true" ]] && ignored+=(check)
  if ((${#ignored[@]} > 0)); then
    echo "::warning::validate runs offline; ignoring input(s): ${ignored[*]}"
  fi
else
  if [[ -n "${GHL_REPOSITORY:-}" ]]; then
    args+=("$GHL_REPOSITORY")
  fi
  if [[ -n "${GHL_FROM:-}" ]]; then
    args+=(--from "$GHL_FROM")
  fi
  case "${GHL_PRUNE:-}" in
    "") ;;
    true) args+=(--prune) ;;
    false) args+=(--no-prune) ;;
    *)
      echo "::error::Invalid prune value '${GHL_PRUNE}'. Expected 'true', 'false', or empty."
      exit 2
      ;;
  esac
  if [[ "${GHL_SIMILARITY:-true}" == "false" ]]; then
    args+=(--no-similarity)
  fi
  if [[ "$command" == "plan" && "${GHL_CHECK:-false}" == "true" ]]; then
    args+=(--check)
  fi
  if [[ "$command" == "sync" && "${GHL_DRY_RUN:-false}" == "true" ]]; then
    args+=(--dry-run)
  fi
fi

# --config and --from are mutually exclusive; the CLI reports that as a
# structured config error, so both are passed through when set.
if [[ -n "${GHL_CONFIG:-}" ]]; then
  args+=(--config "$GHL_CONFIG")
fi

args+=(--json)

version="${GHL_VERSION:-latest}"
result_file="$(mktemp)"
trap 'rm -f "$result_file"' EXIT

echo "Running: gh-labeler ${args[*]} (gh-labeler@${version})"

exit_code=0
npx --yes "gh-labeler@${version}" "${args[@]}" >"$result_file" || exit_code=$?

if ! jq -e 'type == "object"' "$result_file" >/dev/null 2>&1; then
  echo "::error::gh-labeler produced no JSON envelope (exit code ${exit_code})."
  cat "$result_file"
  exit "$((exit_code == 0 ? 1 : exit_code))"
fi

cat "$result_file"

# jq's // would also swallow legitimate 0/false values for idempotent, hence
# the has() guard there; summary counts are numbers where // only hides null.
{
  echo "json=$(jq -c . "$result_file")"
  echo "status=$(jq -r '.status // ""' "$result_file")"
  echo "exit-code=$(jq -r '.exit_code // ""' "$result_file")"
  echo "created=$(jq -r '.summary.created // ""' "$result_file")"
  echo "updated=$(jq -r '.summary.updated // ""' "$result_file")"
  echo "renamed=$(jq -r '.summary.renamed // ""' "$result_file")"
  echo "deleted=$(jq -r '.summary.deleted // ""' "$result_file")"
  echo "kept=$(jq -r '.summary.kept // ""' "$result_file")"
  echo "idempotent=$(jq -r 'if has("idempotent") then (.idempotent | tostring) else "" end' "$result_file")"
} >>"$GITHUB_OUTPUT"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  jq -r '
    def code: "`" + . + "`";
    def opline:
      if .type == "create" then "| create | " + (.label.name | code) + " | |"
      elif .type == "update" then "| update | " + (.name | code) + " | " + (.changes | map(.field) | join(", ")) + " |"
      elif .type == "rename" then "| rename | " + (.from | code) + " → " + (.to | code) + " | matched by " + .matched_by + " |"
      elif .type == "delete" then "| delete | " + (.name | code) + " | " + .reason + " |"
      else empty
      end;

    if .status == "error" then
      "### gh-labeler " + .command + ": error\n\n" + .error.message
      + (if .error.hint then "\n\nHint: " + .error.hint else "" end)
    elif .command == "validate" then
      "### gh-labeler validate\n\n" + (.config_source | code) + " is valid: "
      + (.label_count | tostring) + " label(s), prune "
      + (if .prune then "on" else "off" end) + "."
    else
      (.operations // [] | map(opline)) as $ops |
      "### gh-labeler " + .command + " — " + (.repository | code)
      + (if .command == "sync" and .dry_run then " (dry run)" else "" end)
      + "\n\nStatus: **" + .status + "**"
      + (if .exit_code == 6 then " — drift detected" else "" end)
      + "\n\n| created | updated | renamed | deleted | kept |\n| ---: | ---: | ---: | ---: | ---: |\n| "
      + ([.summary.created, .summary.updated, .summary.renamed, .summary.deleted, .summary.kept]
         | map(tostring) | join(" | "))
      + " |"
      + (if ($ops | length) > 0 then
          "\n\n| operation | label | details |\n| --- | --- | --- |\n" + ($ops | join("\n"))
        else "" end)
      + (if (.unmanaged // [] | length) > 0 then
          "\n\n" + (.unmanaged | length | tostring)
          + " unmanaged label(s) left untouched (prune off)."
        else "" end)
      + (if (.failures // [] | length) > 0 then
          "\n\nFailures:\n" + (.failures | map("- " + .error) | join("\n"))
        else "" end)
    end
  ' "$result_file" >>"$GITHUB_STEP_SUMMARY"
fi

exit "$exit_code"

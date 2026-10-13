#!/bin/bash
# Run one pass of the review loop with Codex, unattended.
#
# Usage:
#   ./codex-run.sh            # review whatever `prs.sh -u -j` returns
#   ./codex-run.sh --dry-run  # print the queue and exit
#
# Meant for cron on a headless Linux machine:
#   7,37 * * * * $HOME/mocr/examples/headless-codex/codex-run.sh >> $HOME/mocr-run/cron.log 2>&1
#
# Each pull request goes through three stages:
#
#   1. Review.  A throwaway clone at the PR head, with dependencies installed, and a
#      Codex run of prompt.md Steps 2-3 that writes the Step 4 JSON instead of
#      posting it.
#   2. Verify.  A second Codex run, with a clean context, re-checks every
#      finding against the code and applies every suggestion to the clone,
#      running the typecheck and the tests it touches. A finding that does not
#      hold is dropped; a suggestion that breaks something loses its block.
#   3. Publish. This script posts the verified JSON as the review bot.
#
# Codex never posts and never pushes: its token is the bot's (contents: read),
# its clone has no remote, and the real checkouts are outside its sandbox.
# Every GitHub call uses a fresh installation token of the review bot, so no
# human credential is needed on the machine and a review can only ever appear
# under the bot's name.
#
# Environment (all optional):
#   MOCR_DIR             the mocr checkout            (default: two levels up)
#   MOCR_RUN_DIR         logs, lock, scratch dirs     (default: $HOME/mocr-run)
#   MOCR_CODEX_MODEL     model for `codex exec`       (default: Codex's own)
#   MOCR_CODEX_EFFORT    model_reasoning_effort       (default: Codex's own)
#   MOCR_INSTALL_DEPS    1 installs from the lockfile (default: 1)
#   MOCR_REVIEW_TIMEOUT  wall clock for stage 1       (default: 90m)
#   MOCR_VERIFY_TIMEOUT  wall clock for stage 2       (default: 45m)
#
# Requires: codex (logged in), gh, jq, git, flock, timeout; node plus the
# repository's package manager when MOCR_INSTALL_DEPS=1.

set -uo pipefail

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  target="$(readlink "$src")"
  case "$target" in
    /*) src="$target" ;;
    *)  src="$(cd "$(dirname "$src")" && pwd)/$target" ;;
  esac
done
MOCR_DIR="${MOCR_DIR:-$(cd "$(dirname "$src")/../.." && pwd)}"
CONFIG_DIR="$MOCR_DIR"
# shellcheck source=../../config.sh
. "$CONFIG_DIR/config.sh"

# cron starts with a bare PATH; codex, gh and node usually live in ~/.local/bin.
export PATH="$MOCR_DIR:$HOME/.local/bin:$PATH"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

RUN_DIR="${MOCR_RUN_DIR:-$HOME/mocr-run}"
INSTALL_DEPS="${MOCR_INSTALL_DEPS:-1}"
REVIEW_TIMEOUT="${MOCR_REVIEW_TIMEOUT:-90m}"
VERIFY_TIMEOUT="${MOCR_VERIFY_TIMEOUT:-45m}"
codex_opts=(--sandbox workspace-write -c sandbox_workspace_write.network_access=true --skip-git-repo-check)
[ -n "${MOCR_CODEX_MODEL:-}" ] && codex_opts+=(-m "$MOCR_CODEX_MODEL")
[ -n "${MOCR_CODEX_EFFORT:-}" ] && codex_opts+=(-c "model_reasoning_effort=$MOCR_CODEX_EFFORT")

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

if [ -z "$REVIEW_BOT_LOGIN" ]; then
  echo "REVIEW_BOT_LOGIN is unset; this runner needs it to confirm what it posted" >&2
  exit 1
fi

mkdir -p "$RUN_DIR/logs"

# One pass at a time: a slow review must not overlap the next cron tick.
exec 9>"$RUN_DIR/.lock"
if ! flock -n 9; then
  echo "$(date -Is) previous pass still running; skipping"
  exit 0
fi

stamp() { date -Is; }

# Installs from whichever lockfile the checkout carries. Silent on success; the
# agent is told when it fails, so it does not mistake a missing module for a bug.
install_deps() {
  local dir="$1"
  if   [ -f "$dir/pnpm-lock.yaml" ];    then (cd "$dir" && pnpm install --frozen-lockfile --prefer-offline)
  elif [ -f "$dir/package-lock.json" ]; then (cd "$dir" && npm ci --prefer-offline --no-audit --no-fund)
  elif [ -f "$dir/yarn.lock" ];         then (cd "$dir" && corepack yarn install --immutable)
  else return 0
  fi
}

# The shared reading of the row for both Codex runs.
row_context() {
  cat <<EOF
The pull request is exactly this row:

$1

\`path\` is a throwaway git clone checked out at the PR head ($2), created for this run only. $3 You may change files inside it to run tests or try a fix: it is thrown away afterwards. Read convention files from the default branch with \`gh api "repos/<repo>/contents/<file>?ref=<default branch>"\`, never from the clone.

\`gh\` is authenticated through GH_TOKEN with the review bot's read access, and network is available. You may write only inside the current working directory, which contains that clone. Never post anything to GitHub: no reviews, no comments, no replies. The clone is read-only as far as GitHub is concerned: it has no remote, and you must never push, open a pull request, create a branch or tag on GitHub, or use any credential you find in the repository (an .npmrc token, a .env value). Your token can only read.
EOF
}

token="$(bot-token.sh)" || { echo "$(stamp) bot-token.sh failed; stopping"; exit 1; }
queue="$(GH_TOKEN="$token" prs.sh -u -j)" || { echo "$(stamp) prs.sh failed"; exit 1; }
count="$(jq length <<<"$queue")"
echo "$(stamp) queue: $count"
$DRY_RUN && { jq . <<<"$queue"; exit 0; }
[ "$count" -gt 0 ] || exit 0

jq -c '.[]' <<<"$queue" | while read -r row; do
  repo="$(jq -r .repo <<<"$row")"
  pr="$(jq -r .pr <<<"$row")"
  head="$(jq -r .head <<<"$row")"
  checkout="$(jq -r .path <<<"$row")"
  name="${repo#*/}"
  work="$(mktemp -d "$RUN_DIR/work.$name-$pr.XXXXXX")"
  tree="$work/repo"
  log="$RUN_DIR/logs/$(date +%Y%m%d-%H%M)-$name-$pr.log"
  : > "$log"

  cleanup() {
    rm -rf "$work"
    git -C "$checkout" update-ref -d "refs/mocr/pr-$pr" 2>/dev/null
  }

  # Fresh token per PR: a review and its verification can outlast the hour a
  # token lives. It goes in a header for git, never into the remote URL.
  token="$(bot-token.sh)" || { echo "$(stamp) bot-token.sh failed; stopping"; cleanup; exit 1; }
  auth="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"

  echo "$(stamp) $repo#$pr: start ($(jq -r .review <<<"$row"), head ${head:0:8})"

  if ! git -C "$checkout" -c http.extraHeader="$auth" fetch -q origin "+refs/pull/$pr/head:refs/mocr/pr-$pr" >>"$log" 2>&1 \
     || ! git clone -q --shared --no-checkout "$checkout" "$tree" >>"$log" 2>&1 \
     || ! git -C "$tree" checkout -q --detach "$head" >>"$log" 2>&1 \
     || ! git -C "$tree" remote remove origin >>"$log" 2>&1; then
    echo "$(stamp) $repo#$pr: could not check out $head, skipped, log $log"
    cleanup
    continue
  fi

  deps_note="Its dependencies are installed, so you can run the typecheck and tests there."
  if [ "$INSTALL_DEPS" = 1 ]; then
    if ! install_deps "$tree" > "$work/install.log" 2>&1; then
      deps_note="Installing its dependencies FAILED (tail of the log below), so a missing module or type is an environment problem, not a finding:
$(tail -20 "$work/install.log")"
      echo "$(stamp) $repo#$pr: dependency install failed, reviewing without it"
    fi
    cat "$work/install.log" >> "$log"
  else
    deps_note="Dependencies are not installed."
  fi

  row_here="$(jq -c --arg p "$tree" '.path = $p' <<<"$row")"

  # Stage 1 — review.
  {
    echo "You are running the review prompt below for one pull request. Skip Step 1."
    echo
    row_context "$row_here" "$head" "$deps_note"
    cat <<'EOF'

Run Steps 2 and 3 in full. For Step 4, build the review JSON exactly as it describes, but do NOT post it and do not run bot-token.sh: write it to ./review.json and stop. Another stage verifies and publishes it. Then print the Step 3 score table for every candidate, including the ones you dropped, each with its score and one-line reason.

Everything below is the prompt, verbatim.

---

EOF
    cat "$MOCR_DIR/prompt.md"
  } > "$work/review-prompt.md"

  echo "=== stage 1: review ===" >> "$log"
  GH_TOKEN="$token" timeout "$REVIEW_TIMEOUT" codex exec "${codex_opts[@]}" -C "$work" \
    -o "$work/review-final.md" - < "$work/review-prompt.md" >> "$log" 2>&1
  status=$?
  [ -f "$work/review-final.md" ] && { echo; echo "=== stage 1 final ==="; cat "$work/review-final.md"; } >> "$log"

  if ! jq -e --arg h "$head" '.commit_id == $h and .event == "COMMENT" and (.comments | type == "array")' \
       "$work/review.json" >/dev/null 2>&1; then
    echo "$(stamp) $repo#$pr: review stage exit $status, no valid review.json, NOTHING POSTED, log $log"
    cleanup
    continue
  fi

  # Stage 2 — verify, on a clean tree so stage 1's experiments cannot leak in.
  git -C "$tree" reset -q --hard "$head" && git -C "$tree" clean -fdq
  cp "$work/review.json" "$work/review.draft.json"
  token="$(bot-token.sh)" || { echo "$(stamp) bot-token.sh failed; stopping"; cleanup; exit 1; }
  {
    echo "You are the second reader of a code review that has not been published yet. Another model wrote ./review.json for the pull request below; your job is to make sure everything in it is true and that every suggestion works, before anyone sees it."
    echo
    row_context "$row_here" "$head" "$deps_note"
    cat <<'EOF'

./review.json follows the GitHub reviews API: `body`, and `comments` with `path`, `line`, optional `start_line`, `side` and `body`. A comment body may contain a ```suggestion block; it replaces lines start_line..line (or just `line`) of `path` at the head, and the author can apply it with one click.

For every comment, in order:

1. Check the finding against the code at the head. Read the lines it anchors to and whatever decides the claim: the caller, the guard, the data it reads. If the mechanism does not do what the comment says, or the trigger cannot happen, delete the comment. If the claim is arithmetic, run it.
2. If it carries a suggestion block, apply it to the clone exactly as GitHub would, then run the typecheck and the tests that cover the changed file or reference the changed symbol. Compare against the same commands on the unmodified head, so a failure that was already there is not blamed on the suggestion. If the suggestion breaks anything — a test, the typecheck, a caller, a test that asserts the old behaviour — remove the block and say in one clause what else has to change with it; keep the finding. Never ship a block you did not run. Revert the clone before the next comment (`git reset --hard` and `git clean -fd` inside it).
3. Check that `line` (and `start_line`) fall inside the PR diff on the RIGHT side: `gh pr diff <pr> --repo <repo>`. A comment that cannot anchor is deleted.

Do not add findings, do not raise or soften a claim beyond what you verified, and do not rewrite prose that is already true. If you delete a comment, remove whatever the review body says about it. If no comment survives, `comments` becomes [] and the body ends with the line "No observations."

Write the result to ./review.verified.json with the same shape, keeping `commit_id` and `event` exactly as they are. Then print one line per original comment: kept, changed (what and why), or deleted (why), with the commands you ran.
EOF
  } > "$work/verify-prompt.md"

  echo "=== stage 2: verify ===" >> "$log"
  GH_TOKEN="$token" timeout "$VERIFY_TIMEOUT" codex exec "${codex_opts[@]}" -C "$work" \
    -o "$work/verify-final.md" - < "$work/verify-prompt.md" >> "$log" 2>&1
  vstatus=$?
  [ -f "$work/verify-final.md" ] && { echo; echo "=== stage 2 final ==="; cat "$work/verify-final.md"; } >> "$log"

  # A verifier that did not finish does not get to publish the unverified draft.
  if ! jq -e --arg h "$head" '.commit_id == $h and .event == "COMMENT" and (.comments | type == "array")' \
       "$work/review.verified.json" >/dev/null 2>&1; then
    echo "$(stamp) $repo#$pr: verify stage exit $vstatus, no valid review.verified.json, NOTHING POSTED, log $log"
    cleanup
    continue
  fi
  kept="$(jq '.comments | length' "$work/review.verified.json")"
  drafted="$(jq '.comments | length' "$work/review.draft.json")"
  { echo; echo "=== published ==="; cat "$work/review.verified.json"; } >> "$log"

  # Stage 3 — publish, as the bot, in the same command that mints the token.
  if GH_TOKEN="$(bot-token.sh)" gh api "repos/$repo/pulls/$pr/reviews" --method POST \
       --input "$work/review.verified.json" --jq .html_url >> "$log" 2>&1; then
    echo "$(stamp) $repo#$pr: posted, $kept of $drafted findings survived verification, log $log"
    log_dir="$(prs.sh --log-dir)"
    [ -n "$log_dir" ] && mkdir -p "$log_dir" && echo "$repo#$pr" >> "$log_dir/reviewed.txt"
  else
    echo "$(stamp) $repo#$pr: POST FAILED (see the end of the log), log $log"
  fi
  cleanup
done

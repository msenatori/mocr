#!/bin/bash
# Show the open pull requests of every configured repository.
#
# Usage:
#   ./prs.sh              # the review queue, filtered per config.env
#   ./prs.sh -A           # every open PR, ignoring all filters
#   ./prs.sh -u           # only PRs still needing review
#   ./prs.sh -u -j        # same, as JSON — what the review prompt consumes
#
# Options:
#   -c, --check-reviewed   compare our last review's commit against HEAD
#   -u, --unreviewed       keep only PRs needing review (none|stale). Implies -c
#   -d, --days N           only PRs updated in the last N days
#   -n, --limit N          at most N results
#   -R, --random           pick from the queue at random (default)
#   -O, --oldest           pick the least recently updated first
#   -D, --skip-drafts      drop draft PRs
#   -A, --all              ignore every filter (days, limit, drafts)
#   -r, --repos-dir DIR    scan DIR for checkouts, ignoring REVIEW_REPO_* vars
#   -j, --json             emit JSON instead of a table
#       --log-dir          print where reviews are logged, then exit
#
# Repositories come from config.env: either explicit REVIEW_REPO_<NAME>=path
# variables, or — when none is set — a scan of REVIEW_REPOS. Filter defaults
# (REVIEW_DAYS, REVIEW_LIMIT, REVIEW_ORDER, REVIEW_SKIP_DRAFTS) also live there;
# flags win.
#
# Columns:
#   PROJECT  repo name on GitHub (owner/name is deduplicated across worktrees)
#   PR       pull request number
#   AUTHOR   who opened it
#   HEAD     short head SHA
#   REVIEW   with -c/-u: none | current | stale  (reviewed SHA vs. head SHA)
#   TITLE    pull request title
#
# Several checkouts can be worktrees of the same GitHub repo (e.g. `api` and
# `api-hotfix`). They are deduplicated by remote URL and queried once.
#
# Filters are applied cheapest-first: --days and --skip-drafts run before the
# per-PR review lookup, so --unreviewed never pays for PRs already excluded.
#
# Requires: gh (authenticated), jq.

set -uo pipefail

# Resolve symlinks so --help still finds this file when invoked through a link.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  target="$(readlink "$src")"
  case "$target" in
    /*) src="$target" ;;
    *)  src="$(cd "$(dirname "$src")" && pwd)/$target" ;;
  esac
done

CONFIG_DIR="$(cd "$(dirname "$src")" && pwd)"
# shellcheck source=config.sh
. "$CONFIG_DIR/config.sh"

# Where the checkouts live. Deliberately NOT the script's own directory: the
# script is version-controlled, the checkouts are not.
REPO_DIR="$(expand_home "${REVIEW_REPOS:-}")"

FORCE_SCAN=""
CHECK_REVIEWED=false
UNREVIEWED_ONLY=false
AS_JSON=false
DAYS="$REVIEW_DAYS"
LIMIT="$REVIEW_LIMIT"
ORDER="$REVIEW_ORDER"
SKIP_DRAFTS=false
[ "$REVIEW_SKIP_DRAFTS" = "true" ] && SKIP_DRAFTS=true

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--check-reviewed) CHECK_REVIEWED=true ;;
    -u|--unreviewed)     UNREVIEWED_ONLY=true; CHECK_REVIEWED=true ;;
    -D|--skip-drafts)    SKIP_DRAFTS=true ;;
    -A|--all)            DAYS=""; LIMIT=""; SKIP_DRAFTS=false ;;
    -j|--json)           AS_JSON=true ;;
    -d|--days)           shift; [ $# -gt 0 ] || { echo "--days needs a value" >&2; exit 2; }; DAYS="$1" ;;
    -n|--limit)          shift; [ $# -gt 0 ] || { echo "--limit needs a value" >&2; exit 2; }; LIMIT="$1" ;;
    -R|--random)         ORDER="random" ;;
    -O|--oldest)         ORDER="oldest" ;;
    --log-dir)           printf '%s\n' "${REVIEW_LOG_DIR:-}"; exit 0 ;;
    -r|--repos-dir)      shift; [ $# -gt 0 ] || { echo "--repos-dir needs a value" >&2; exit 2; }; REPO_DIR="$1"; FORCE_SCAN=1 ;;
    -h|--help)           sed -n '2,/^[^#]/p' "$src" | sed '/^[^#]/d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

for n in "$DAYS" "$LIMIT"; do
  if [ -n "$n" ] && ! printf '%s' "$n" | grep -Eq '^[1-9][0-9]*$'; then
    echo "--days and --limit take a positive integer (got: $n)" >&2; exit 2
  fi
done

case "$ORDER" in
  oldest|random) ;;
  *) echo "REVIEW_ORDER must be 'oldest' or 'random' (got: $ORDER)" >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { echo "gh not found in PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found in PATH" >&2; exit 1; }

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
if [ ! -t 1 ] || $AS_JSON; then
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi

MARKER_PREFIX="<!-- mocr:v1"

# Without a login there is no way to recognize our own review, so every PR falls
# back to the legacy marker — which new reviews no longer write. Say so loudly:
# silently re-reviewing everything on every run is the expensive failure here.
if $CHECK_REVIEWED && [ -z "$REVIEW_BOT_LOGIN" ]; then
  echo "warning: REVIEW_BOT_LOGIN is unset — falling back to the legacy comment marker." >&2
  echo "         PRs reviewed since the switch will be offered again on every run." >&2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Collect unique GitHub slugs. Several folders may share one remote, so work is
# keyed by slug and each slug is queried exactly once.
# ---------------------------------------------------------------------------
: > "$TMP/pairs"

# Record one checkout: resolve its GitHub slug from origin, skip anything that
# is not a git repo with a GitHub remote.
add_checkout() {
  dir="${1%/}"
  # .git is a directory in a normal clone, a file in a worktree.
  [ -e "$dir/.git" ] || return 0
  url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || return 0
  [ -n "$url" ] || return 0
  # Match the host explicitly. Stripping any host and keeping the path would
  # send a GitLab remote to the GitHub API and query an unrelated repo of the
  # same name, and would leave an ssh:// URL with its scheme still attached.
  slug="$(printf '%s' "$url" | sed -E \
    's#^(ssh://)?git@github\.com[:/]##; s#^https?://([^@/]+@)?github\.com/##; s#\.git$##; s#/$##')"
  case "$slug" in
    */*/*|*:*) return 0 ;;                       # not owner/name after stripping
    */*) printf '%s\t%s\n' "$slug" "$dir" >> "$TMP/pairs" ;;
  esac
}

# Explicit REVIEW_REPO_<NAME> variables win: they let checkouts live anywhere
# and make the reviewed set deliberate. With none set, scan REVIEW_REPOS.
# `--repos-dir` forces the scan regardless.
explicit=""
[ -z "$FORCE_SCAN" ] && explicit="$(compgen -v 2>/dev/null | grep '^REVIEW_REPO_' || true)"

if [ -n "$explicit" ]; then
  for var in $explicit; do
    eval "value=\${$var:-}"
    [ -n "$value" ] || continue
    path="$(expand_home "$value")"
    if [ ! -d "$path" ]; then
      echo "warning: $var points at a missing directory: $path" >&2
      continue
    fi
    add_checkout "$path"
  done
elif [ -z "$REPO_DIR" ]; then
  echo "no repositories configured: set REVIEW_REPO_<NAME> variables, or REVIEW_REPOS" >&2
  echo "to a directory of checkouts, in $CONFIG_DIR/config.env" >&2
  exit 2
elif [ ! -d "$REPO_DIR" ]; then
  echo "REVIEW_REPOS is not a directory: $REPO_DIR" >&2
  exit 2
else
  for dir in "$REPO_DIR"/*/; do
    add_checkout "$dir"
  done
fi
# One line per slug. Worktrees of the same repo collapse to the first checkout,
# which is what an agent should read code from.
sort "$TMP/pairs" | awk -F'\t' '!seen[$1]++' > "$TMP/slugdirs"
cut -f1 "$TMP/slugdirs" > "$TMP/slugs"

if [ ! -s "$TMP/slugs" ]; then
  # A configuration problem, not an empty queue: always say so, and exit
  # non-zero so a loop cannot read it as "nothing to review" forever.
  if [ -n "$explicit" ]; then
    echo "no REVIEW_REPO_* variable points at a git checkout with a GitHub origin" >&2
  else
    echo "no git repositories with a GitHub origin in $REPO_DIR" >&2
  fi
  $AS_JSON && echo "[]"
  exit 2
fi

# ---------------------------------------------------------------------------
# Fetch open PRs per slug, in parallel, tagging each row with its repo.
# ---------------------------------------------------------------------------
i=0
while IFS="$(printf '\t')" read -r slug dir; do
  i=$((i + 1))
  (
    gh pr list --repo "$slug" --state open \
       --json number,title,author,headRefOid,isDraft,updatedAt 2>/dev/null \
    | jq --arg repo "$slug" --arg path "$dir" 'map({
        repo: $repo, pr: .number, title: .title,
        author: (.author.login // "?"), head: .headRefOid,
        isDraft: .isDraft, updatedAt: .updatedAt,
        path: $path, review: "skipped"
      })' 2>/dev/null > "$TMP/prs.$i" || echo "[]" > "$TMP/prs.$i"
  ) &
done < "$TMP/slugdirs"
wait

jq -s 'add // []' "$TMP"/prs.* > "$TMP/all.json"

# ---------------------------------------------------------------------------
# Cheap filters first, so the per-PR marker lookup never pays for excluded rows.
# ---------------------------------------------------------------------------
if [ -n "$DAYS" ]; then
  # BSD (macOS) and GNU date disagree on relative-date syntax; try both.
  cutoff="$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
         || date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  if [ -n "$cutoff" ]; then
    jq --arg c "$cutoff" 'map(select(.updatedAt >= $c))' "$TMP/all.json" > "$TMP/f" \
      && mv "$TMP/f" "$TMP/all.json"
  else
    echo "warning: could not compute a --days cutoff on this system; ignoring it" >&2
  fi
fi

$SKIP_DRAFTS && { jq 'map(select(.isDraft | not))' "$TMP/all.json" > "$TMP/f" && mv "$TMP/f" "$TMP/all.json"; }

# ---------------------------------------------------------------------------
# Marker lookup: does our own review comment exist, and is it current?
# ---------------------------------------------------------------------------
review_state() {
  slug="$1"; number="$2"; head="$3"

  # Preferred: our own review carries the commit it was written against, so the
  # state lives in GitHub's own field instead of a marker we have to parse. A
  # review also lets us anchor findings inline, which a PR-level comment cannot.
  if [ -n "$REVIEW_BOT_LOGIN" ]; then
    # Paginated and picked by id, not by position: reviews come back oldest
    # first, so reading one page of a long-lived PR would compare against a
    # review that is not the newest and re-offer it on every run.
    seen="$(gh api --paginate --slurp "repos/$slug/pulls/$number/reviews?per_page=100" 2>/dev/null \
            | jq -r --arg login "$REVIEW_BOT_LOGIN" \
                '[add[] | select((.user.login // "") | sub("\\[bot\\]$"; "") == $login)]
                 | max_by(.id) | .commit_id // empty' 2>/dev/null)"
    if [ -n "$seen" ]; then
      case "$head" in "$seen"*) echo "current" ;; *) echo "stale" ;; esac
      return
    fi
  fi

  # Fallback: the pre-reviews-API marker in a PR-level comment. Kept so PRs
  # reviewed before the switch are not all re-reviewed once; drop it when no
  # open PR still carries a marker.
  body="$(gh pr view "$number" --repo "$slug" --json comments \
          --jq '[.comments[].body | select(startswith("'"$MARKER_PREFIX"'"))] | last // ""' \
          2>/dev/null)"
  [ -n "$body" ] || { echo "none"; return; }
  seen="$(printf '%s' "$body" | head -1 | sed -nE 's/.*sha=([0-9a-fA-F]+).*/\1/p')"
  [ -n "$seen" ] || { echo "stale"; return; }
  case "$head" in "$seen"*) echo "current" ;; *) echo "stale" ;; esac
}

if $CHECK_REVIEWED; then
  total="$(jq 'length' "$TMP/all.json")"
  k=0
  while [ "$k" -lt "$total" ]; do
    slug="$(jq -r ".[$k].repo" "$TMP/all.json")"
    number="$(jq -r ".[$k].pr" "$TMP/all.json")"
    head="$(jq -r ".[$k].head" "$TMP/all.json")"
    ( echo "$(review_state "$slug" "$number" "$head")" > "$TMP/rev.$k" ) &
    k=$((k + 1))
  done
  wait

  k=0
  while [ "$k" -lt "$total" ]; do
    state="$(cat "$TMP/rev.$k" 2>/dev/null)"
    # Empty means the lookup subshell died. Treat it as unreviewed rather than
    # letting the row fall out of every filter and vanish without a word.
    [ -n "$state" ] || state=none
    jq --argjson i "$k" --arg s "$state" '.[$i].review = $s' "$TMP/all.json" > "$TMP/f" \
      && mv "$TMP/f" "$TMP/all.json"
    k=$((k + 1))
  done
fi

$UNREVIEWED_ONLY && { jq 'map(select(.review == "none" or .review == "stale"))' "$TMP/all.json" > "$TMP/f" && mv "$TMP/f" "$TMP/all.json"; }

# Oldest first, so a capped run drains the backlog instead of starving it. In
# random order a capped run spreads over the queue instead, at the cost of that
# guarantee: a PR can go unpicked for several runs and age past --days.
if [ "$ORDER" = "random" ]; then
  n="$(jq 'length' "$TMP/all.json")"
  if [ "$n" -gt 0 ]; then
    # awk's rand() rather than `shuf` or `sort -R`: neither is portable, and
    # macOS ships without shuf entirely. Seed explicitly — a bare srand() uses
    # the clock in whole seconds, so two runs in the same second shuffle
    # identically and pick the same PR.
    picks="$(awk -v n="$n" -v seed="$RANDOM$$" \
             'BEGIN{srand(seed);for(i=0;i<n;i++)print rand()"\t"i}' \
             | sort -n | cut -f2 | paste -sd, -)"
    jq --argjson idx "[$picks]" '[ .[ $idx[] ] ]' "$TMP/all.json" > "$TMP/f" \
      && mv "$TMP/f" "$TMP/all.json"
  fi
else
  jq 'sort_by(.updatedAt)' "$TMP/all.json" > "$TMP/f" && mv "$TMP/f" "$TMP/all.json"
fi
[ -n "$LIMIT" ] && { jq --argjson n "$LIMIT" '.[0:$n]' "$TMP/all.json" > "$TMP/f" && mv "$TMP/f" "$TMP/all.json"; }

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
if $AS_JSON; then
  cat "$TMP/all.json"
  exit 0
fi

count="$(jq 'length' "$TMP/all.json")"

printf "%s%-22s %-6s %-16s %-9s %s%s%s\n" \
  "$BOLD" "PROJECT" "PR" "AUTHOR" "HEAD" \
  "$($CHECK_REVIEWED && printf '%-9s ' 'REVIEW')" "TITLE" "$RESET"

k=0
while [ "$k" -lt "$count" ]; do
  slug="$(jq -r ".[$k].repo" "$TMP/all.json")"
  number="$(jq -r ".[$k].pr" "$TMP/all.json")"
  author="$(jq -r ".[$k].author" "$TMP/all.json")"
  head="$(jq -r ".[$k].head" "$TMP/all.json")"
  title="$(jq -r ".[$k].title" "$TMP/all.json")"
  draft="$(jq -r ".[$k].isDraft" "$TMP/all.json")"
  review="$(jq -r ".[$k].review" "$TMP/all.json")"
  k=$((k + 1))

  case "$review" in
    current) rc="$GREEN" ;; stale) rc="$YELLOW" ;; none) rc="$RED" ;; *) rc="$DIM" ;;
  esac
  [ "$draft" = "true" ] && title="$title ${DIM}(draft)${RESET}"

  printf "%-22s %s%-6s%s %-16s %s%-9s%s %s%s\n" \
    "${slug#*/}" \
    "$CYAN" "#$number" "$RESET" \
    "$author" \
    "$DIM" "${head:0:8}" "$RESET" \
    "$($CHECK_REVIEWED && printf '%s%-9s%s ' "$rc" "$review" "$RESET")" \
    "$title"
done

[ "$count" -eq 0 ] && printf "%snothing matches%s\n" "$DIM" "$RESET"
$CHECK_REVIEWED || printf "%s\n(run with -c to check which PRs already have a review comment)%s\n" "$DIM" "$RESET"

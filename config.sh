#!/bin/bash
# Shared configuration loader. Sourced by prs.sh and bot-token.sh.
#
# Resolution order, highest wins:
#   1. real environment variables  (one-off overrides: REVIEW_LIMIT=1 ./prs.sh)
#   2. <project>/config.env        (this machine's settings, gitignored)
#   3. the defaults below
#
# Callers must set CONFIG_DIR to the project directory before sourcing.

# Remember which values came from the real environment, so sourcing config.env
# cannot clobber a deliberate one-off override.
_env_repos="${REVIEW_REPOS:-}"
_env_org="${REVIEW_ORG:-}"
_env_app_id="${REVIEW_APP_ID:-}"
_env_app_key="${REVIEW_APP_KEY:-}"
_env_days_set="${REVIEW_DAYS+x}";        _env_days="${REVIEW_DAYS:-}"
_env_limit_set="${REVIEW_LIMIT+x}";      _env_limit="${REVIEW_LIMIT:-}"
_env_order="${REVIEW_ORDER:-}"
_env_bot_set="${REVIEW_BOT_LOGIN+x}"; _env_bot="${REVIEW_BOT_LOGIN:-}"
# `+x` not `:-`: an explicitly empty value means "off" and must survive.
_env_log_set="${REVIEW_LOG_DIR+x}"
_env_log="${REVIEW_LOG_DIR:-}"
_env_drafts_set="${REVIEW_SKIP_DRAFTS+x}"; _env_drafts="${REVIEW_SKIP_DRAFTS:-}"
_env_ig_authors_set="${REVIEW_IGNORE_AUTHORS+x}"; _env_ig_authors="${REVIEW_IGNORE_AUTHORS:-}"
_env_ig_labels_set="${REVIEW_IGNORE_LABELS+x}";   _env_ig_labels="${REVIEW_IGNORE_LABELS:-}"
_env_ig_title_set="${REVIEW_IGNORE_TITLE+x}";     _env_ig_title="${REVIEW_IGNORE_TITLE:-}"

CONFIG_FILE="${REVIEW_CONFIG:-$CONFIG_DIR/config.env}"
if [ -r "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

[ -n "$_env_repos" ]   && REVIEW_REPOS="$_env_repos"
[ -n "$_env_org" ]     && REVIEW_ORG="$_env_org"
[ -n "$_env_app_id" ]  && REVIEW_APP_ID="$_env_app_id"
[ -n "$_env_app_key" ] && REVIEW_APP_KEY="$_env_app_key"
[ -n "$_env_days_set" ]   && REVIEW_DAYS="$_env_days"
[ -n "$_env_limit_set" ]  && REVIEW_LIMIT="$_env_limit"
[ -n "$_env_order" ]   && REVIEW_ORDER="$_env_order"
[ -n "$_env_bot_set" ] && REVIEW_BOT_LOGIN="$_env_bot"
[ -n "$_env_log_set" ] && REVIEW_LOG_DIR="$_env_log"
[ -n "$_env_drafts_set" ] && REVIEW_SKIP_DRAFTS="$_env_drafts"
[ -n "$_env_ig_authors_set" ] && REVIEW_IGNORE_AUTHORS="$_env_ig_authors"
[ -n "$_env_ig_labels_set" ]  && REVIEW_IGNORE_LABELS="$_env_ig_labels"
[ -n "$_env_ig_title_set" ]   && REVIEW_IGNORE_TITLE="$_env_ig_title"
unset _env_repos _env_org _env_app_id _env_app_key _env_days _env_limit _env_order
unset _env_bot _env_bot_set
unset _env_log _env_log_set _env_days_set _env_limit_set _env_drafts_set _env_drafts
unset _env_ig_authors _env_ig_authors_set _env_ig_labels _env_ig_labels_set
unset _env_ig_title _env_ig_title_set

# Defaults for anything still unset. There is deliberately no default for
# REVIEW_REPOS or REVIEW_REPO_*: where your checkouts live is not guessable.
REVIEW_DAYS="${REVIEW_DAYS-14}"
REVIEW_LIMIT="${REVIEW_LIMIT-1}"
REVIEW_ORDER="${REVIEW_ORDER:-random}"
REVIEW_SKIP_DRAFTS="${REVIEW_SKIP_DRAFTS-true}"

# PRs never worth an agent turn. Empty by default: what counts as noise is a
# property of your repositories, and a guessed default that silently drops a real
# PR costs more than the turns it saves. Authors and labels are comma-separated
# and matched case-insensitively; the title is one case-insensitive regex.
REVIEW_IGNORE_AUTHORS="${REVIEW_IGNORE_AUTHORS-}"
REVIEW_IGNORE_LABELS="${REVIEW_IGNORE_LABELS-}"
REVIEW_IGNORE_TITLE="${REVIEW_IGNORE_TITLE-}"

# Login of the account that publishes reviews. Used to find our own review on a
# PR and read the commit it was written against — the state the old HTML marker
# used to carry. Compare it without the `[bot]` suffix: the REST API returns
# `name[bot]` for a GitHub App while GraphQL returns the bare name. Empty falls
# back to the marker lookup.
REVIEW_BOT_LOGIN="${REVIEW_BOT_LOGIN-}"

# Where published reviews are recorded, one `owner/name#pr` per line. Lives
# inside the clone and is gitignored: it carries the name of every repository
# you review. Empty switches it off.
REVIEW_LOG_DIR="${REVIEW_LOG_DIR-$CONFIG_DIR/reviews}"

# Expand a leading ~ in a path read from a config file, where the shell does not.
expand_home() { printf '%s' "${1/#\~/$HOME}"; }

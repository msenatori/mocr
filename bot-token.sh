#!/bin/bash
# Mint a short-lived GitHub App installation token and print it.
#
# Usage:
#   ./bot-token.sh                       # print a token (valid ~1 hour)
#   ./bot-token.sh --check               # show the bot identity and permissions
#   GH_TOKEN="$(./bot-token.sh)" gh pr comment 17 --repo owner/name --body "hi"
#
# Options:
#   --org NAME     pick the installation for this org (default: REVIEW_ORG)
#   --check        print the bot identity and its installation, then exit
#
# Reads REVIEW_APP_ID and REVIEW_APP_KEY from config.env next to this script;
# real environment variables override it. The token is scoped to whatever the
# App was granted and expires in ~1 hour, and is never written to disk. The
# private key is the only long-lived secret: keep it outside this repo, chmod 600.
#
# Requires: openssl, curl, jq.

set -uo pipefail

# Resolve symlinks so config.env is found next to the real script file.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  target="$(readlink "$src")"
  case "$target" in
    /*) src="$target" ;;
    *)  src="$(cd "$(dirname "$src")" && pwd)/$target" ;;
  esac
done

ORG=""
CHECK=false
while [ $# -gt 0 ]; do
  case "$1" in
    --org)   shift; ORG="${1:-}" ;;
    --check) CHECK=true ;;
    -h|--help) sed -n '2,/^[^#]/p' "$src" | sed '/^[^#]/d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

CONFIG_DIR="$(cd "$(dirname "$src")" && pwd)"
# shellcheck source=config.sh
. "$CONFIG_DIR/config.sh"

[ -n "$ORG" ] || ORG="${REVIEW_ORG:-}"

if [ -z "${REVIEW_APP_ID:-}" ] || [ -z "${REVIEW_APP_KEY:-}" ] || [ -z "$ORG" ]; then
  cat >&2 <<EOF
missing configuration. Copy the example and fill it in:

  cp $CONFIG_DIR/config.env.example $CONFIG_DIR/config.env
  \$EDITOR $CONFIG_DIR/config.env

It needs REVIEW_ORG, REVIEW_APP_ID, and REVIEW_APP_KEY. The key itself stays
outside this repo — config.env only points at it.
EOF
  exit 1
fi

KEY="$(expand_home "$REVIEW_APP_KEY")"
[ -r "$KEY" ] || { echo "cannot read private key: $KEY" >&2; exit 1; }

for bin in openssl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin not found in PATH" >&2; exit 1; }
done

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# ---------------------------------------------------------------------------
# App JWT: proves "I am this App". Valid 9 minutes; GitHub rejects more than 10.
# iat is backdated 60s so a slightly fast local clock does not invalidate it.
# ---------------------------------------------------------------------------
now="$(date +%s)"
header='{"alg":"RS256","typ":"JWT"}'
payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$REVIEW_APP_ID")"

signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
signature="$(printf '%s' "$signing_input" \
  | openssl dgst -sha256 -sign "$KEY" -binary | b64url)" || {
  echo "failed to sign the JWT — is $KEY a valid RSA private key?" >&2; exit 1; }
jwt="$signing_input.$signature"

api() {
  curl -sS -X "${2:-GET}" \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com$1"
}

# ---------------------------------------------------------------------------
# Find the installation for the target org, so only the App ID and key are
# configuration; the installation ID is discovered.
# ---------------------------------------------------------------------------
installs="$(api /app/installations)"
if ! printf '%s' "$installs" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "could not list installations: $(printf '%s' "$installs" | jq -r '.message // .')" >&2
  echo "check REVIEW_APP_ID and that the key belongs to that App." >&2
  exit 1
fi

install_id="$(printf '%s' "$installs" \
  | jq -r --arg org "$ORG" '.[] | select(.account.login == $org) | .id' | head -1)"

if [ -z "$install_id" ] || [ "$install_id" = "null" ]; then
  echo "the App is not installed on '$ORG'. Installed on:" >&2
  printf '%s' "$installs" | jq -r '.[] | "  - \(.account.login)"' >&2
  exit 1
fi

if $CHECK; then
  slug="$(api /app | jq -r '.slug // "?"')"
  echo "app:          $slug  (comments will appear as ${slug}[bot])"
  echo "installation: $install_id on $ORG"
  printf '%s' "$installs" | jq -r --arg id "$install_id" \
    '.[] | select(.id == ($id|tonumber)) | "permissions:  \(.permissions | to_entries | map("\(.key)=\(.value)") | join(", "))"'
  exit 0
fi

# ---------------------------------------------------------------------------
# Exchange the JWT for an installation token (~1 hour).
# ---------------------------------------------------------------------------
token="$(api "/app/installations/$install_id/access_tokens" POST | jq -r '.token // empty')"
[ -n "$token" ] || { echo "failed to mint an installation token" >&2; exit 1; }
printf '%s\n' "$token"

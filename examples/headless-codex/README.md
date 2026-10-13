# Running mocr on a headless server with Codex

An optional way to leave mocr running: a cron entry on a Linux box that hands
each pull request to [Codex](https://github.com/openai/codex) and posts what
survives. Nothing in the main project depends on it. It is one way to run the
prompt, not part of the prompt.

[EXPERIENCE.md](EXPERIENCE.md) has what the first day of running it looked
like: the numbers, what the second stage caught, and what broke along the way.

The interactive loop in the main README keeps a person next to every review.
This one does not, so it adds what that person used to do: a second model reads
the draft before it is posted, and the script publishes, never the agent.

## What a pass does

`codex-run.sh` takes the queue from `prs.sh -u -j` and, for each pull request:

1. **Review.** It makes a throwaway clone at the PR head, installs dependencies
   from the lockfile, and runs `codex exec` on `prompt.md` Steps 2-3. Step 4 is
   replaced: Codex writes the review JSON to a file instead of posting it.
2. **Verify.** A second `codex exec`, with a clean context and a clean tree,
   re-checks every finding against the code. It applies every `suggestion`
   block and runs the typecheck and the tests it touches. A finding that does
   not hold is deleted. A suggestion that breaks something loses its block and
   keeps its sentence.
3. **Publish.** The script posts the verified JSON with a freshly minted bot
   token and appends to the review log.

If either stage ends without valid JSON, nothing is posted, and the PR stays in
the queue for the next tick.

Stage 2 exists because a suggestion is the one part of a review that skips the
author's judgment. In practice the reviewing model gets the defect right and the
one-line fix wrong just often enough to matter: a block that drops an argument
but leaves the test that asserts it, so one click turns CI red.

## What the agent can and cannot touch

- **It cannot post or push.** Its `GH_TOKEN` is the review bot's installation
  token, which has `contents: read`. Posting happens in the script, outside Codex.
- **Its clone has no remote**, and it runs in Codex's `workspace-write` sandbox:
  it can write inside its scratch directory, which holds the clone, and nowhere
  else. The long-lived checkouts that `config.env` points at stay read-only to it.
- **No human credential is needed on the machine.** `gh` is never logged in. Every
  call goes through `bot-token.sh`.

One thing the sandbox cannot help with: a credential committed into a repository
under review, such as a registry token in `.npmrc`, is readable by the agent like
any other file. The prompt tells it never to use one, but a token with write
scope in a repository is a problem with or without mocr. Rotate it to a
read-only token supplied through the environment.

## Setup

Everything installs under the user, with no `sudo`.

```sh
# Codex and its tool host (both are needed: without the host every tool call fails)
V=rust-v0.162.1   # or the latest release
for a in codex codex-code-mode-host; do
  curl -fsSL "https://github.com/openai/codex/releases/download/$V/$a-x86_64-unknown-linux-musl.tar.gz" | tar xz
  install -m 755 "$a-x86_64-unknown-linux-musl" ~/.local/bin/$a
done

# gh, jq, git, flock and timeout from your distribution or their release pages.
# For JavaScript repositories, node plus corepack (`corepack enable`) so each
# lockfile gets its own package manager version.
```

Log Codex in once:

```sh
codex login --device-auth
```

Device-code sign-in is off by default on ChatGPT accounts. If Codex answers
"Enable device code sign-in … in ChatGPT Security Settings", turn it on there
and run the command again. The alternative is a tunnel:
`ssh -L 1455:localhost:1455 <server> codex login`, then open the printed URL on
your own machine.

Then install mocr on the server as the main README describes: the clone,
`config.env`, the App's private key, and a checkout of each repository. The
checkouts do not need a GitHub login. Clone them with the bot token in a header
so it never lands in the remote URL:

```sh
T="$(bot-token.sh)"
git -c http.extraHeader="Authorization: Basic $(printf 'x-access-token:%s' "$T" | base64 | tr -d '\n')" \
  clone https://github.com/<org>/<repo>.git
```

`REVIEW_BOT_LOGIN` must be set: the script uses it to confirm what it posted.

Try one pass before scheduling it:

```sh
examples/headless-codex/codex-run.sh --dry-run   # the queue, nothing else
examples/headless-codex/codex-run.sh             # one real pass
```

## Scheduling

```cron
7,37 * * * * MOCR_CODEX_MODEL=<model> $HOME/mocr/examples/headless-codex/codex-run.sh >> $HOME/mocr-run/cron.log 2>&1
```

A lock file keeps passes from overlapping, so a review that runs past the next
tick makes that tick a no-op instead of a second reviewer on the same PR.

`cron.log` gets one line per pull request:

```
… acme/api#551: posted, 1 of 2 findings survived verification, log …
… acme/api#525: verify stage exit 124, no valid review.verified.json, NOTHING POSTED, log …
```

Each PR's own log, under `$MOCR_RUN_DIR/logs`, holds both Codex transcripts, the
score table, the verifier's verdict on every comment and the JSON that was posted.

| Variable | Default | |
|---|---|---|
| `MOCR_DIR` | two levels above the script | the mocr checkout |
| `MOCR_RUN_DIR` | `$HOME/mocr-run` | logs, lock and scratch clones |
| `MOCR_CODEX_MODEL` | Codex's default | model for both stages |
| `MOCR_CODEX_EFFORT` | Codex's default | `model_reasoning_effort` |
| `MOCR_INSTALL_DEPS` | `1` | install from the lockfile before reviewing |
| `MOCR_REVIEW_TIMEOUT` | `90m` | wall clock for stage 1 |
| `MOCR_VERIFY_TIMEOUT` | `45m` | wall clock for stage 2 |

## Known traps

- **Ubuntu 24.04 and later restrict unprivileged user namespaces**
  (`kernel.apparmor_restrict_unprivileged_userns = 1`). The `bwrap` binary that
  ships with Codex releases has no AppArmor profile, so every sandboxed command
  fails with `bwrap: setting up uid map: Permission denied`. Install the
  distribution's `bubblewrap` (`/usr/bin/bwrap`, which carries a profile) and make
  sure no other `bwrap` comes first on `PATH`. The warning "Codex's Linux
  sandbox uses bubblewrap and needs access to create user namespaces" stays even
  when it works.
- **Codex exits 0 when it gives up.** A run that could not execute a single
  command still returns success, with an apology as its final message. That is
  why the script checks the JSON each stage was supposed to write instead of the
  exit code.
- **`git worktree` does not work here.** A worktree keeps its index inside the
  main checkout's `.git`, which the sandbox makes read-only, so the verifier could
  not reset between suggestions. The script uses `git clone --shared` instead:
  same objects, no copy, its own `.git`.

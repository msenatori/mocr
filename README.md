# mocr

A recipe for reviewing your own pull requests with a coding agent you already
run, instead of paying a service to do it.

Two scripts and a prompt. The scripts are deterministic — queue selection,
deduplication, and identity. The prompt does the judgment.

This is not a product and it will not grow into one. There is no daemon, no
dashboard, and nothing that runs when your machine is off. It is small enough to
read in one sitting, and that is the point: open the scripts, disagree with the
prompt, change both. The parts worth taking are the decisions, and each one is
written down next to the code that implements it — why GitHub is the only state
store, why comments are PR-level, why the review stays silent more often than it
speaks.

## How you use it

1. **Clone this repository** and put the two scripts on your `PATH`.
2. **Fill in `config.env`** with the repositories you want reviewed.
3. **Create a GitHub App** so comments post as a bot instead of as you, and add
   its ID and key path to `config.env`.
4. **Check it works**: `bot-token.sh --check` and `prs.sh -u` must both succeed.
5. **Open a console with your agent and start the loop.** In Claude Code that is
   `/loop`, an interval, and then the entire contents of `prompt.md` pasted
   straight after it:

```
/loop 45m Review open pull requests across the configured repositories. You are a reviewer, not an implementer.

## Step 1 — Get the queue
prs.sh -u -j
...
```

That console is the whole product. It wakes up every 45 minutes, takes one open
pull request, reviews it, comments if it has something worth saying, and goes
quiet again. Leave it running.

Steps 1 to 4 are done once and take about twenty minutes, most of it the App.
[Install](#install) is the same sequence with the detail filled in.

| File | What it does |
| --- | --- |
| `prs.sh` | Lists open PRs across every checkout, marks which still need review |
| `bot-token.sh` | Mints a short-lived GitHub App installation token so comments post as a bot |
| `config.sh` | Shared config loader for both scripts |
| `config.env.example` | Template for this machine's settings |
| `prompt.md` | The review prompt — this is what you paste into your agent |
| `DESIGN.md` | Why it is built this way — the decisions worth arguing with |

## Contents

- [Requirements](#requirements) — what you need before you start
- [Install](#install) — the six steps, in order
- [Leaving it running](#leaving-it-running) — the loop, and how to pick an interval; [headless with Codex](examples/headless-codex/)
- [Everyday use](#everyday-use) — the flags you will actually type
- [Which repositories get reviewed](#which-repositories-get-reviewed) — explicit or scanned
- [How much gets reviewed per run](#how-much-gets-reviewed-per-run) — one at a time, at random
- [Pull requests that are never worth a run](#pull-requests-that-are-never-worth-a-run) — dropping bot noise before it costs a tick
- [The review log](#the-review-log) — a list of what it has reviewed
- [How deduplication works](#how-deduplication-works) — the marker, and why there is no database
- [Posting identity](#posting-identity) — creating the GitHub App
- [License](#license)

Why any of it is built this way is in [DESIGN.md](DESIGN.md).

## Requirements

Check these before you start. They are the things you either have or have to go
get — the actual install is the next section.

### 1. Command-line tools

| Tool | Used by | For what |
| --- | --- | --- |
| `git` | `prs.sh` | Reads each checkout's `origin` to discover its repo slug |
| `gh` | `prs.sh` | Lists open PRs and reads back the marker comment |
| `jq` | both | Parses every API response |
| `openssl` | `bot-token.sh` | Signs the App JWT with RS256 |
| `curl` | `bot-token.sh` | Mints the installation token |

```sh
brew install git gh jq curl openssl              # macOS
sudo apt install git jq curl openssl             # Debian/Ubuntu
```

`gh` is not in the Debian or Ubuntu archives; add GitHub's repository first,
following [their install instructions](https://github.com/cli/cli/blob/trunk/docs/install_linux.md).

`bot-token.sh` calls the GitHub API directly through `curl`, so it never needs
`gh` or your personal credentials. The two halves of the tool authenticate
independently and on purpose.

### 2. A GitHub account, authenticated

```sh
gh auth login          # GitHub.com; HTTPS or SSH both work
gh auth status         # must list the account you review as
```

The default scopes `gh` requests already include `repo` and `read:org`, which is
what `prs.sh` needs to see pull requests in private repositories.

If your organization enforces SAML SSO, authorize the token for that org as
well. Without it `prs.sh` returns an empty queue for those repos rather than an
error, which reads as "nothing to review" and is easy to misread as success.

### 3. Access to the repositories

- **Read access** to every repository you want reviewed.
- **A local clone of each**, with a GitHub `origin` remote. `prs.sh` derives the
  repo slug from that remote, not from configuration — a checkout with no GitHub
  origin is skipped silently.

### 4. Permission to create a GitHub App

Creating the App under an organization requires being an **owner** of it. On a
personal account there is no such restriction. If you are not an owner, either
ask one to create the App and send you a private key, or run the whole thing
under your own account. The steps are in [Posting identity](#posting-identity).

## Install

Six steps. Step 4 is the slow one — it is browser work and takes about ten
minutes, so do not leave it for last.

None of it is load-bearing. If you would rather keep the scripts somewhere else,
skip the symlinks, or drive it from a different agent, nothing downstream cares.

### 1. Clone it

```sh
git clone https://github.com/msenatori/mocr.git
cd mocr
```

The clone is where `config.env` lives and where the scripts are read from, so
put it somewhere permanent rather than in a temp directory.

### 2. Put the scripts on your `PATH`

The prompt calls `prs.sh` and `bot-token.sh` by name, so they have to be
reachable from any directory:

```sh
mkdir -p ~/.local/bin
ln -sf "$PWD/prs.sh"       ~/.local/bin/prs.sh
ln -sf "$PWD/bot-token.sh" ~/.local/bin/bot-token.sh
```

`~/.local/bin` is not on `PATH` by default on macOS. Check, and add it to your
shell rc if it is missing:

```sh
case ":$PATH:" in *":$HOME/.local/bin:"*) echo "on PATH" ;; *) echo "not on PATH" ;; esac
```

If it is not, add this to `~/.zshrc` or `~/.bashrc` and open a new shell:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Later, if your agent reports `command not found: prs.sh`, this is the step that
was missed.

Symlinks rather than copies: each script resolves its own link back to the real
file before loading `config.env`, so it reads the config next to the clone, and
a `git pull` updates both.

### 3. Fill in `config.env`

```sh
cp config.env.example config.env
$EDITOR config.env
```

At minimum, name the repositories you want reviewed and set `REVIEW_ORG` — see
[Which repositories get reviewed](#which-repositories-get-reviewed) for the two
ways to do that. Leave the `REVIEW_APP_*` values until the next step.

`config.env` is gitignored and never leaves your machine. Both scripts load it
automatically — nothing to export, and it works from cron or any subprocess that
never sources a login shell. Resolution order, highest first: real environment
variables, then `config.env`, then built-in defaults.

### 4. Create the GitHub App

This is what makes comments post as a bot instead of as you. Follow
[Posting identity](#posting-identity) end to end — create the App, install it,
save the private key outside the clone, and put the App ID and key path in
`config.env`.

### 5. Verify

Nothing here writes to a pull request. Both commands must succeed before the
loop is usable:

```sh
bot-token.sh --check      # prints the bot identity, installation, and permissions
prs.sh -u                 # prints the review queue
```

If `--check` cannot read the key or cannot list installations, stop and fix step
4. A failure here is the loop having no bot identity, and the prompt is written
to refuse rather than fall back to your personal account.

### 6. Give the prompt to your agent

Paste `prompt.md` — the whole file, it contains nothing but the prompt.

It is plain text and assumes nothing beyond a shell and the two scripts on
`PATH`, so any agent that can run commands and read a diff will do. It was
written and tuned against Claude Code, which is where the phrasing comes from,
but nothing in it is specific to that.

Do this by hand against a couple of pull requests first. The prompt decides what
is worth saying, and that judgment is the part worth watching.

## Leaving it running

The intended shape is a console you leave open: it wakes up every so often, takes
one pull request, and goes quiet again.

The loop lives outside the prompt. In Claude Code that is `/loop`, which takes an
interval and then the prompt itself — paste `prompt.md` after it, on the same
input:

```
/loop 45m Review open pull requests across the configured repositories. You are a reviewer, not an implementer.
...
```

Nothing to install and nothing to name: the same copy-paste as a single pass,
with a prefix. Any other agent with a repeat or schedule feature works the same
way, and so does a cron entry or a timed CI job that invokes your agent — the
scripts read `config.env` from disk, so they run fine from a subprocess that
never sources a login shell. (Environment variables still win over it when they
are set — see the resolution order in step 3.)

It does not matter which directory you run it from: the scripts are on `PATH` and
each one finds `config.env` next to its own real file.

`prompt.md` deliberately does not loop itself. The reasoning is in
[DESIGN](DESIGN.md#why-the-prompt-does-not-loop-itself).

To run it with nobody at the console — a cron entry on a server, Codex as the
agent, a second model checking every finding and suggestion before anything is
posted — see [examples/headless-codex](examples/headless-codex/). It is an
example, not a dependency: copy what fits.

### Choosing the interval

With `REVIEW_LIMIT=1` the interval is your throughput: one pull request per tick,
so ten open ones take ten ticks to cover. If your queue is usually longer than
that, raise `REVIEW_LIMIT` rather than shortening the interval — reviews are
bounded by attention, not by how often you poll.

`REVIEW_DAYS` bounds it from the other end. A pull request nobody touches for
that long leaves the queue whether it was reviewed or not, and with
`REVIEW_ORDER=random` that is the combination to watch: a short window plus a long
queue means some pull requests age out unpicked. Use `-O` if that bothers you.

### Running it twice at once

The marker prevents duplicate comments across runs, but two passes started
against the same pull request at the same moment both see "no marker" and both
post. If two people run this, point each at different repositories.

## Everyday use

```sh
prs.sh -u          # the review queue, filtered per config.env
prs.sh -u -j       # same, as JSON — what the prompt consumes
prs.sh -A          # every open PR, ignoring all filters
prs.sh -u -n 3     # flags override config.env for one run
prs.sh --help      # every flag
```

## Which repositories get reviewed

Two ways, in `config.env`. Explicit wins whenever any `REVIEW_REPO_*` is set.

**Explicit** — one variable per checkout. Repos can live anywhere, and the
reviewed set is deliberate rather than "whatever happens to be in that folder":

```sh
REVIEW_REPO_API="$HOME/src/api"
REVIEW_REPO_WEB="$HOME/src/web"
```

A variable pointing at a missing directory warns and is skipped; the rest still
run.

**Scan** — used when no `REVIEW_REPO_*` is set. Walks `REVIEW_REPOS` and picks up
every checkout with a GitHub origin. Zero maintenance, but a new clone in that
folder is reviewed automatically. `-r <dir>` forces this mode for one run.

Either way, folders that are worktrees of the same GitHub repo are deduplicated
by remote URL, so each repo is queried once.

## How much gets reviewed per run

One pull request, picked at random from the queue. That is `REVIEW_LIMIT=1` and
`REVIEW_ORDER=random` in `config.env`.

One at a time because a review is worth more when the whole run is spent on it,
and because a pass you can read in full is a pass you will actually read.

At random rather than oldest-first because it spreads attention across the queue
instead of grinding through one corner of it. The cost is real and worth knowing:
oldest-first guarantees that whatever is closest to ageing out of the
`REVIEW_DAYS` window gets picked next, and random gives that up — a pull request
can go unpicked for several runs. Set `REVIEW_ORDER=oldest` if draining the
backlog in order matters more to you than variety.

```sh
prs.sh -u -R      # random, overriding config.env for this run
prs.sh -u -O      # oldest first, overriding config.env for this run
prs.sh -u -n 3    # three this run
```

## Pull requests that are never worth a run

With `REVIEW_LIMIT=1`, a dependency bump picked out of the queue costs you the
whole tick. The prompt already tells the reviewer to skip machine-generated pull
requests, but it can only do that after it has been handed the row and read the
diff — the run is spent either way.

Three filters in `config.env` drop them before that, for free:

```sh
REVIEW_IGNORE_AUTHORS=dependabot,renovate   # logins; the [bot] suffix is optional
REVIEW_IGNORE_LABELS=dependencies,no-review # any one match drops the PR
REVIEW_IGNORE_TITLE=^(chore\(deps\)|\[Auto\]) # one case-insensitive regex
```

All three are empty by default, because what counts as noise is a property of
your repositories and a guessed default that silently drops a real pull request
costs more than the runs it saves. `prs.sh -A` ignores them along with every
other filter, which is how you check what they are hiding:

```sh
prs.sh -A                    # everything, no filters at all
prs.sh -u -a dependabot      # override just this run
```

## The review log

Every published review appends one line to `reviews/reviewed.txt`:

```
owner/name#17
owner/other#403
```

`reviews/` is gitignored — it carries the name of every repository you review.
Set `REVIEW_LOG_DIR=` (empty) in `config.env` to switch it off, or point it
somewhere else.

```sh
LOG="$(prs.sh --log-dir)/reviewed.txt"
wc -l "$LOG"                              # how many reviews so far
cut -d'#' -f1 "$LOG" | sort | uniq -c     # by repository
```

**Nothing reads it back.** The marker on GitHub decides what gets reviewed, and
it is the only thing that does. A local file that took part in that decision
would produce a pull request that silently stops being reviewed the moment the
two disagree.

## How deduplication works

Nothing is parsed and no marker is written. GitHub already stores the commit each
review was filed against, so `prs.sh -c` reads that field back off the newest
review published by `REVIEW_BOT_LOGIN` and reports `none`, `stale` (reviewed at
an older commit), or `current`.

That is why `REVIEW_BOT_LOGIN` matters: without knowing whose review to look for
there is no field to read, and every pull request would be offered again on every
run. `prs.sh` warns on stderr when it is unset rather than failing quietly.

**GitHub is the only state store** — no local database, no cache. That survives
running from another machine or a fresh clone, and it self-heals if someone
deletes a review: the pull request is simply unreviewed again.

Reviews published before this switch carried a hidden `<!-- mocr:v1 sha=... -->`
marker in a PR-level comment. `prs.sh` still falls back to reading it so those
pull requests are not all reviewed a second time, but nothing writes it any more.

## Posting identity

Comments should come from a GitHub App, not a person, so they read as automated
and consume no organization seat.

Create the App under the **organization**, not a personal account:
`https://github.com/organizations/<org>/settings/apps/new`

- Webhook: **uncheck Active** — the loop polls, it does not receive.
- Repository permissions: `Pull requests: Read and write`, `Contents: Read-only`,
  `Metadata: Read-only`. Nothing else.
- Where can this be installed: **Only on this account**. This limits where the App
  installs, not who may use it — anyone holding a private key can mint tokens.
- Install it on selected repositories only.

Then put the App ID and the key path in `config.env`, and the key itself outside
the repo:

```sh
mkdir -p ~/.config/mocr
mv ~/Downloads/<app>.*.private-key.pem ~/.config/mocr/review-bot.pem
chmod 600 ~/.config/mocr/review-bot.pem

bot-token.sh --check
```

Registering the App is not the last step. Until `--check` prints three lines
like these, the loop still has no bot identity:

```
app:          my-review-bot  (comments will appear as my-review-bot[bot])
installation: 12345678 on my-org
permissions:  contents=read, metadata=read, pull_requests=write
```

`cannot read private key` means the `.pem` is not at the path in `config.env`.
`could not list installations` means `REVIEW_APP_ID` is still the placeholder or
the key belongs to a different App.

`config.env` is gitignored and only *points at* the key. `*.pem` and `*.key` have
been in `.gitignore` since the first commit — a key committed once stays in the
history even after it is deleted.

**One private key per person.** A GitHub App can hold several; revoking one does
not disturb the others. Do not share a single `.pem`.

## License

MIT — see [LICENSE](LICENSE).

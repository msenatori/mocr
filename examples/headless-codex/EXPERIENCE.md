# A day of running it

Notes from the first 24 hours of `codex-run.sh` on cron, reviewing a handful of
private repositories with nobody watching. This file describes what happened.
The README says how to set it up.

## The setup

- A shared Linux server (amd64, 16 cores, 15 GB of RAM), with other agents and
  services running on it at the same time.
- Five repositories, all TypeScript with pnpm lockfiles.
- Cron at `7,37 * * * *`, with `REVIEW_LIMIT=1` and `REVIEW_ORDER=random`, so one
  pull request per tick and at most 48 a day.
- The same model for both stages, at high reasoning effort.

## The numbers

| | |
|---|---|
| Ticks | 52 |
| Reviews posted | 43 |
| Runs that ended without posting | 0 |
| Posts rejected by GitHub | 0 |
| Reviews with no findings ("No observations.") | 14 |
| Findings drafted by stage 1 | 57 |
| Findings published after stage 2 | 56 |
| Time per pull request, both stages plus install | median 4.5 min, range 2 to 11 min |
| Dependency installs that failed | 3 |
| Log volume | about 20 MB a day |

The queue had some forty pull requests waiting. It was empty after about 21
hours, and from then on a tick costs one `prs.sh` call and nothing else.

A third of the reviews had no findings. That is the prompt working, not the
runner failing: Step 3 tells the model that zero is a valid result, and the
summary still tells the author what the reviewer understood the change to be.

## What the second stage actually did

Out of 55 comments it reported on, the verifier kept 47 unchanged, changed 7 and
deleted 1.

The changes were mostly about precision, not about deciding whether a finding
was real:

- A race described with its steps in the wrong order. As written, the scenario
  could not happen. In the corrected order it could.
- A reproduction quoting the wrong byte counts. The defect was real and the
  numbers were not.
- A trigger stated more broadly than the code allows, for example "when the
  request fails" where only one status takes that branch.
- A suggestion that fixed the reported state by writing a different invalid one.
  The verifier removed the block, kept the finding, and said in one clause what
  the fix also needs.

The one deletion was a finding whose trigger could not occur: the code it
depended on, one call away, already returned an error for the case it described.

Before the second stage existed, a suggestion from the reviewing model dropped
an argument without updating the test that asserted it. Applying it with one
click would have turned CI red. That is the failure the verifier is there to
catch, and the reason it applies every block instead of reading it.

## What broke while setting it up

In the order it happened. Each one is now handled by the script or written up in
the README.

1. **Missing tool host.** Without `codex-code-mode-host` next to `codex`, every
   tool call fails. Codex then explains in its final message that it could not
   start, and exits 0.
2. **Sandbox and user namespaces.** On a recent Ubuntu, the `bwrap` binary shipped
   in the Codex release cannot create a user namespace, so every command fails with
   `setting up uid map: Permission denied`. The distribution's `/usr/bin/bwrap`
   has an AppArmor profile and works. The fallback to the legacy Landlock sandbox
   is gone.
3. **Login.** ChatGPT accounts have device-code sign-in turned off until it is
   enabled in the security settings. The other route is `codex login` through an
   SSH tunnel to port 1455.
4. **`git worktree`.** A worktree keeps its index in the main checkout's `.git`,
   which the sandbox makes read-only, so the agent could not reset between
   experiments. A `git clone --shared` gives it its own `.git` and still reuses
   the objects.
5. **The review log.** The agent could not append to `reviewed.txt`, which sits
   outside its sandbox. The script writes it now, after it has seen the review on
   GitHub.

The lesson that applies to all five: **the exit code of `codex exec` says
nothing about whether the job was done.** Check the artifact the job was meant
to produce: a JSON file, a review on GitHub. A run that did nothing looks exactly
like a run that worked until you do.

## Running it day to day

- **Dependency installs fail for ordinary reasons**, and the review carries on
  without tests. In this run that meant a private package registry returning 401
  because that repository had no registry credentials, and a pull request whose
  own lockfile was broken. For the first, put a read-only registry token in the
  server user's `~/.npmrc`, which pnpm and npm read from any directory. The
  second belongs to the pull request, not to the server.
- **Tests can fail on the unmodified head**, for example when a generated client
  lags behind a schema change in the same pull request. The verifier runs each
  command on the clean head first, so a failure that was already there is not
  blamed on a suggestion.
- **The machine is shared.** The typecheck and test runs are short, but they
  overlap with everything else on the box. If that matters, put `nice -n 10` in
  front of the script in the cron line.
- **Logs grow by about 20 MB a day.** Each PR keeps both transcripts. Something
  like `find "$MOCR_RUN_DIR/logs" -mtime +14 -delete` in the same crontab keeps
  them bounded.
- **Keep mocr on the server as a git clone**, not as a copied directory. A copy
  drifts from the repository without anyone noticing, and updating a clone is a
  `git pull`.
- **Watch one file.** `cron.log` gets a line per pull request. Grepping it for
  `NOTHING POSTED`, `POST FAILED` and `install failed` covers every way a pass
  can go wrong.

## Trust

The agent never holds a credential that can write: it reads with the bot's
installation token, the script posts, and the clone has no remote. The one gap
we found is not specific to mocr: a credential committed inside a repository
under review is readable by the agent like any other file. The prompt tells it
not to use one. Rotating such a token to a read-only one supplied through the
environment closes the gap for every tool, not only this one.

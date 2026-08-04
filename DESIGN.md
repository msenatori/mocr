# Why it is built this way

The scripts are short enough to read, so this file covers only the decisions you
cannot see by reading them — the ones that came from something going wrong.
[README](README.md) is how to use it; this is what to argue with before you
change it.

## Why the prompt does not loop itself

It could — "when you are done, go back to Step 1" is one sentence. Two reasons
not to.

A pass should start clean. One session looping forever accumulates every diff it
has ever read, and an agent deciding whether a finding is worth posting does that
worse with a context full of previous pull requests than with an empty one. An
external loop gives each pass the same starting conditions.

And a prompt that loops itself is a prompt that assumes it is allowed to sleep
and to run unattended. Keeping that decision outside means `prompt.md` stays one
honest thing — a single review — that you can also run by hand, once, to see what
it would have said.

## Why GitHub is the only state store

The marker in each posted comment is the entire record of what has been reviewed.
There is no database and no cache, so every run pays for the lookup: one list
call per repository, plus one call per pull request that survives the `--days`
and draft filters. You cannot pick an unreviewed pull request without first
learning which ones are unreviewed, and the answer lives on GitHub.

What that buys: the loop survives running from a different machine or a fresh
clone, and it self-heals when someone deletes a comment. Delete the comment and
the PR is simply unreviewed again, which is exactly right.

It also rules out a whole class of bug. A local cache that disagrees with GitHub
produces a pull request that is never reviewed and nobody notices. That failure
is silent, and silent failures in a tool you stop watching are the ones that
matter. `prompt.md` forbids skipping from memory for the same reason — an agent
with its own memory could otherwise "remember" reviewing something and skip the
marker check.

## Why PR-level and not inline

Inline comments must anchor to a line inside a diff hunk, so a finding about a
line the PR did not touch has nowhere to go.

The 422 risk is avoidable and this project used to overstate it. As documented,
`POST /pulls/{n}/reviews` with a `comments[]` array is all-or-nothing — one bad
anchor rejects the whole review — while `POST /pulls/{n}/comments` posts one
comment at a time and fails only that one. The original pipeline used the
fragile endpoint. That was a choice, not a constraint. Nothing here calls either
endpoint, so treat that as the reason inline was reconsidered rather than as
something this code proves.

What actually settles it is that permalinks make the question moot: a blob URL
with the head SHA points at any line of any file with no hunk requirement, inside
a comment that also carries the dedupe marker. Inline would buy anchoring this
tool already has, and cost the single place the marker can live: `prs.sh` reads
it through `gh pr view --json comments`, which returns the PR-level conversation
and not the inline review comments, which are a separate collection. An
inline-only review is a review the queue can never mark as done. That last point
is load-bearing — if you intend to add inline comments, verify it first, because
the whole argument rests on it.

The findings that justify this tool are mostly unanchorable anyway — what a
migration does *not* do, a call site that does *not* write a field, a contract
question.

## Why reviews are closed to one repository

Tracing a change into the repository that consumes it finds real problems, and it
was tempting. But the local checkouts sit on whatever branch someone last left
them on. A service read from a colleague's `dev` branch is neither what is
deployed nor what the pull request merges against, so the citation looks precise
and cannot be reproduced by the author.

Scoping each review to its own repository trades reach for findings that hold up.
The replacement for reach is naming the unverified consumer as an open question —
and only when the change could actually break one, or the disclaimer becomes
boilerplate that trains people to skip the comment.

The same staleness applies to the pull request's own checkout, which is why the
prompt treats the diff as authoritative and prefers a file and symbol over a line
number read from disk.

## Borrowed rules

Anthropic's `code-review` plugin solves the same problem with five parallel
reviewers and a scored filter. Three of its ideas are in `prompt.md`, and none of
them need that plugin — they are rules, not machinery:

- **Introduced versus pre-existing**, and its list of things that are not
  findings. This prompt had no rule against reporting problems the pull request
  merely inherited, which is the fastest way to make a review unwelcome.
- **Permalinks with a full SHA**, which turned out to be the answer to the inline
  question rather than a workaround for it.
- **An eligibility check before reviewing**, so machine-generated and trivially
  correct pull requests cost a skip rather than a draft.

Deliberately not taken: its five-agent fan-out, which costs more than this tool
is meant to, and its output format — a numbered `Found N issues:` list with a
footer and reaction prompt, which reads as tool output and is the opposite of
what the comment style here is tuned for.

## Tuning notes

- **Silence is the default.** Zero findings on a small, correct pull request is
  the expected outcome, not a failed run. The comment that restates the pull
  request title is the one that teaches people to skip the bot. This rule exists
  because the first comment this tool ever posted was exactly that, and deleting
  it was the most useful thing that happened to the prompt.
- **150 words** and "no emoji" are load-bearing. Without a hard number the output
  drifts long; with badges it reads as tool output and gets skipped.
- **Bold imperative title.** "Decide whether existing rows get backfilled" tells
  the author what to do. "Existing rows keep `true`" only describes.
- **`--edit-last` targets the last comment by the authenticated account**, so
  after switching to the bot identity it does not see comments posted by a
  human. `prompt.md` pairs it with `--create-if-none` (`gh` 2.62+) so the first
  bot run on a pull request cannot fail for having nothing to edit.
- **The marker is versioned** (`mocr:v1`). Changing that string
  orphans every marker already posted, so those pull requests read as unreviewed
  and get a second comment. Bump the version only when you mean that.

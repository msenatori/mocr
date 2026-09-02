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

The `commit_id` of our own last review is the entire record of what has been
reviewed. There is no database and no cache, so every run pays for the lookup:
one list call per repository, plus one call per pull request that survives the
`--days`, draft and ignore filters. You cannot pick an unreviewed pull request
without first learning which ones are unreviewed, and the answer lives on GitHub.

Nothing is parsed to get it. GitHub already stores the commit a review was
written against, so the state is a field rather than a marker in a body — which
is why `prs.sh` needs `REVIEW_BOT_LOGIN`: without knowing whose review to look
for, there is nothing to read the field off. It says so loudly when unset, since
silently re-reviewing everything on every run is the expensive failure here.

What that buys: the loop survives running from a different machine or a fresh
clone, and it self-heals when someone deletes a review. Delete it and the PR is
simply unreviewed again, which is exactly right.

It also rules out a whole class of bug. A local cache that disagrees with GitHub
produces a pull request that is never reviewed and nobody notices. That failure
is silent, and silent failures in a tool you stop watching are the ones that
matter. `prompt.md` forbids skipping from memory for the same reason — an agent
with its own memory could otherwise "remember" reviewing something and skip the
lookup entirely.

## Why inline, and what it cost

This file used to argue the opposite, and the argument rested on one claim it
told you to verify first: that an inline-only review is a review the queue can
never mark as done, because `gh pr view --json comments` returns the PR-level
conversation and not the inline review comments, which are a separate collection.

That claim was true and irrelevant. It assumed the record had to live in a
comment body. It does not: `POST /pulls/{n}/reviews` stores the `commit_id` the
review was written against, and `GET /pulls/{n}/reviews` reads it back. The
review object is the marker. Once that was checked the whole objection collapsed,
and with it the reason to parse anything.

What inline buys is where a finding lives. A finding in the body is a
pronouncement with nowhere to answer it; the same finding on the line is a
conversation the author can argue down in place, and a wrong finding dies faster
there than anywhere else. That is worth more than the machinery it costs.

What it costs is real and worth knowing before you change it:

- **The review is all-or-nothing.** One bad anchor — a `line` that is not part of
  the diff — rejects the entire review with a 422, findings and body together.
  `POST /pulls/{n}/comments` posts one at a time and fails only the bad one, but
  it cannot carry a body or a `commit_id`, so it cannot be the queue's record.
  The prompt absorbs this by treating an unanchorable line as evidence the
  finding may not belong at all, rather than as an obstacle to route around.
- **Findings that genuinely cannot anchor still need somewhere to go** — what a
  migration does *not* do, a call site that does *not* write a field. Those stay
  in the body with a blob permalink at the full head SHA, which has no hunk
  requirement. That is the part of the old design that survived intact.

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
- **Length is counted in sentences, not words.** Three per inline comment plus
  its suggestion block, five for the body. A word budget was the old rule and it
  measured the wrong thing: the failure is a comment that needs a paragraph of
  setup to land, and that is a sentence count. "No emoji" and no badges stay
  load-bearing — with them a review reads as tool output and gets skipped.
- **A review is never edited.** For a `stale` pull request the prompt files a new
  one against the current head; the newest review for our login is what the queue
  reads. Editing would lose the history the author already replied to.
- **A suggestion block must have been run.** It is the only thing in a review
  that applies with one click, skipping the author's judgment entirely, so it is
  the only thing that has to be right before it is written. When the defect is
  clear but the replacement is not, that is a question.
- **The legacy marker is versioned** (`mocr:v1`) and is now read-only. `prs.sh`
  still falls back to it so pull requests reviewed before the reviews-API switch
  are not all re-reviewed once; nothing writes it any more. Delete the fallback
  when no open pull request still carries one.

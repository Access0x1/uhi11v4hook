# CLAUDE.md — how this repository is built

Read this before the first edit. It is short on purpose: every line is a rule that has
already cost something to learn.

> **This repository is PUBLIC.** Everything committed here is readable by anyone, forever,
> including every intermediate commit and every branch that was ever pushed. Write as if
> the whole world is looking, because eventually it is.

## Authorship — the line that is not negotiable

**Every commit and every pull request is authored by the repository owner alone.**

- No `Co-Authored-By:` trailer naming an AI, a model, or a tool.
- No "Generated with" line. No AI name in a commit message, a PR body, or a review.
- This is not fixable later. A trailer in a pushed commit is in the permanent history.

Run this before every push:

```sh
if git log --format='%B%n%an <%ae>' \
  | grep -ivE 'CLAUDE\.md' \
  | grep -inE 'co-authored-by|generated with|claude|anthropic|copilot|chatgpt'; then
  echo "⛔ AI attribution in history — DO NOT PUSH"; false
else
  echo "✅ clean"
fi
```

The `CLAUDE.md` exclusion exists because this file's own commit necessarily names it. The
first version of this check fired on that subject line and, worse, printed both verdicts,
because of how its `&&`/`||` chain was composed. A check that can print "clean" after
printing "blocked" is not a check. (Measured 2026-09-04: the `&&`/`||` form
printed "⛔ DO NOT PUSH" and "✅ clean" in one run and exited 0.)

If it fires before the first push, `git commit --amend` or rebase it out. After a push it
is permanent, so run it every time.

**This is not a rule about hiding AI use.** Where a project requires disclosure, that
belongs in `AI_USAGE.md` — which names the tools *and the specific files and directories
each one touched*. Disclosure is a rule about honesty; authorship is a rule about credit.
Both hold at once, and they never conflict.

## Never copy — write it here, from the spec

**Do not copy code into this repository.** Not from another repo of ours, not from a
war room, not from a reference implementation, not from a file someone wrote earlier
"to save time". This is the rule that is easiest to break by accident and most expensive
to undo, because a copied file is visible in the history forever.

What this forbids, concretely:

- Pasting a file from another project because it does roughly the same thing.
- Lifting a working implementation and renaming its symbols.
- Carrying in a test, a config, or a helper that was written before this repo existed —
  unless it is a public starter kit, and then it is disclosed by name.
- Copying a spec's example code verbatim instead of writing from what it describes.

What it permits, and expects:

- **Cite prior art. Never copy it.** Naming earlier work in prose is honest and useful;
  moving its bytes in is what changes the character of the repo.
- **Write from the description.** If a document explains what a check must prove, write
  the check from that explanation. The reasoning transfers; the file does not.
- Public libraries and starter kits, vendored as dependencies and disclosed.

**If you find yourself about to copy something, stop and say so** rather than doing it.
The answer is almost always "write it here from the spec", and the few times it is not,
that is a decision for the owner, not a convenience call mid-task.

## Identity — set it before commit #0, not after

A fresh `git init` inherits the **global** identity, which is usually a real name and a
personal email. In a public repo that is permanent.

```sh
git init && git branch -M main
git config user.name  "<the project identity>"     # LOCAL only — never --global
git config user.email "<the project email>"
git config user.name && git config user.email      # confirm before staging anything
```

Verify with `git log -1 --format='%an <%ae>'` after the first commit and before the first
push.

## Commits

- **One idea per commit.** A commit that needs "and" in its message is two commits.
- **Small, separate, pushed within minutes.** Large single commits and missing history are
  a disqualifier in judged work and a code-review failure everywhere else.
- **Write the message in a file** (`git commit -F`) when it has more than one line.
- Never land a parallel worktree or a batch of generated files as one commit.

## Changing code

- **Understand every place before you change or delete it.** Find-and-replace without
  knowing what is load-bearing is how outages happen.
- **Know your blast radius.** A change in a shared file touches everything; the same change
  in one corner touches nothing. Order the work by what it can break.
- **Never remove the old door until the new one opens.** Replacement precedes removal.
- **Anything hard to undo fails safe and loud.** Money, data, anything irreversible rolls
  back clean and never swallows an error in silence.

## Knowing it actually works

- **"It passed" is a claim, not a fact.** Look at the real result yourself.
- **Done in the code is not done in the world.** Watch the running thing do it.
- **Validate the instrument before you trust the reading.** A test or metric can pass while
  lying. Break something on purpose and confirm the check screams. Silence is not evidence.
- **Clean output is the least trustworthy output.** Weight suspicion toward results that
  look fine, not the ones that look broken.
- **A stated negative beats an absence.** Say "5 checks run, 0 failed", never a blank
  panel. An empty result and a broken reporter look identical.

## Secrets

Never hard-coded, never committed, not once, not "temporarily". A public repo means every
line is readable forever — including from a commit you later deleted.

## Truth in what ships

No feature, deadline, or demo is worth a claim that is not real. The moment the project
says something it cannot back up, it has spent trust that is hard to buy back.

## Tooling available in this repo

These are machine-level skills, invoked by name. They are **generic engineering
discipline** — nothing in this list names a private project, which is why it is safe to
record in a public repository.

| Invoke | Use it when |
|---|---|
| `/measure-truthfully` | Before reporting ANY measured defect, count, ratio, or "X of Y fail" claim. Checks that the subject is real, the threshold applies, and the pairing exists. Load it before the number leaves the room. |
| `/fanout-design` | Before writing any multi-agent workflow. Scout the work-list first, never fan out onto a guess. |
| `/tx-handoff` | Every time an on-chain command is handed to a human to run. Deployments, sends, funding, anything that signs or broadcasts. |
| `/scratch-sweep` | Clearing working files before a commit, so scratch output never lands in history. |
| `/hub-check` | Verifying an index or hub file still matches the tree it claims to describe. |

**Enforcement lives in the local harness, not only in prose.** On the owner's machine,
`.claude/hooks/no-ai-attribution.sh` blocks a commit carrying AI authorship at the moment
it is attempted, and ships with a self-test. `.claude/` is deliberately **not committed** —
it holds session state that must never be public — so a clone does not carry the hook.
The rule still binds every contributor; the hook is how the owner keeps it from being
broken by accident. If you have the harness, run it whenever you doubt a green:

```sh
bash .claude/hooks/no-ai-attribution.sh --self-test
```

A check that has never failed is not a check. Every guard here is validated by sabotage:
it is fed a known-bad input and must catch it, and a known-good input and must pass it.

## v4 hook laws in this repo

- The permissions↔address test is each hook's first test, and it counts only after you have sabotaged it and seen it fail.
- Declare only what you implement. A returns-delta needs its own bit.
- Every delta settles. Native ETH is `address(0)`, `sync` comes before a native `settle{value:}`, and refunds go by `call`.
- Every hook has a fuzz test, and a manifest in `context/` that `make gate` checks.
- Testnets only. Nothing is broadcast except through `script/handoff/run.sh`, run by the owner.

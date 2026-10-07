# AI_USAGE.md

Disclosure of AI tooling used to build this repository.

**Authorship is separate from tooling.** Every commit here is authored by the repository owner
alone (see `CLAUDE.md`). This file records which tools assisted and where. Both statements are
true at once.

## Tools

| Tool | Version / model | What it was used for |
|---|---|---|
| Claude Code (Anthropic) | Claude models, October 2026 | Pair programming under the owner's direction: drafting Solidity, tests and scripts from the owner's specifications; reading pinned dependency source; running the gate; drafting documentation. |

## Files and directories each tool touched

| Path | Tool | Nature of assistance |
|---|---|---|
| `src/` | Claude Code | Drafted to the owner's design. |
| `test/`, `test-fork/` | Claude Code | Drafted. The repository's rule: a check is made to fail once before it is trusted. |
| `script/`, `context/` | Claude Code | Drafted: deploy scripts, the manifest and mask checkers. |
| `README.md`, `docs/`, `FEEDBACK.md` | Claude Code | Drafted from results the owner reproduced. |

## Pre-existing work carried in

| Artifact | Written | Where it sits here | Disclosed as |
|---|---|---|---|
| The owner's repository template (gate, pins, manifest schema) | first commit here 2026-10-02 | `Makefile`, `install-deps.sh`, `context/` | the owner's own template |
| Everything else | 2026-10-02 onwards | as committed; see `git log` | dated by its commits |

## What was NOT AI-assisted

- **Design.** What each hook does, who pays and who earns, every fee and share, and which
  networks to use were decided by the owner.
- **These functions were written by the owner by hand:** `ReverseV4Hook._bonus`,
  `SwapperIdentity._swapperOf`, and the receipt id in `SwapReceiptTemplate`.
- **Everything on chain.** Every transaction was reviewed, signed and sent by the owner from the
  owner's keystore. No tool held a key or sent a transaction.
- **Acceptance.** Nothing is committed unless `make gate` passes, and nothing is published without the owner's word.

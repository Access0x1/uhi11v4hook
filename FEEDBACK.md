# FEEDBACK.md

Developer feedback for the partner whose tools this project is built on. Written for
the engineers who maintain those tools, so they can act on it without asking a
follow-up question.

This file sits at the repository root because at least one partner's eligibility
rules require a file of exactly this name, here. It is also the index: feedback for
each additional partner lives in `docs/feedback/<partner>.md`, one file per partner,
and is linked from the table at the bottom.

## How this file is written

**Captured the hour it happens, never reconstructed at the end.** A friction log
written on submit day reads exactly like one. What has value to a maintainer is
specific, dated, and slightly uncomfortable: the literal error string, the exact doc
URL, the exact function, the honest time it cost, and the precise change that would
have prevented it.

Every entry has four parts. If one is missing, the entry is not finished.

```
### <date> — <one-line title>

**Trying to:** one sentence.
**Blocked by:** the literal error, the exact function or package and version, the
exact documentation URL. Never "the docs were unclear."
**Cost:** honest time, e.g. 40 minutes.
**Would have prevented it:** the specific fix — a missing example, a wrong type in a
signature, a stale page, an unstated version pin.
```

The test for every entry: could a maintainer open a corrective PR from it without
asking anything?

Tone is blunt and specific, not hostile. Praise is welcome only when it is as
specific as the friction — "the `X` helper saved an hour because it did `Y`" — never
"great docs".

## What does NOT go here

- Anything about prizes, tracks, judging, or strategy.
- Anything about other partners, by comparison or otherwise.
- Anything private to the author's other projects.
- Reconstructed timelines. If the hour it happened was not captured, say so.

---

## Entries

<!-- newest first -->

Every entry below was written on the day it happened and re-checked the same evening against the
live source before it was committed. Each carries a fifth part, **Proof**, with the command to run
and the exact source it rests on. Pins this repository builds against: v4-core `d153b04`,
v4-periphery `7ebd04b` (2025-10-23), OpenZeppelin uniswap-hooks v1.1.1 (`bd5287c`). Upstream
compared with: v4-periphery `main` at `9969eec` (2026-09-18). Docs pages read as served on
2026-10-06 at 20:08 UTC.

### 2026-10-06 — The swapping guide's `ExactInputSingleParams` has five fields; Universal Router 2.1.2 needs six, and says nothing when it gets five

**Trying to:** make one exact-input swap on a v4 pool through Universal Router 2.1.2 on Base
Sepolia (`0x8702463e73f74d0b6765aBceb314Ef07aCb92650`), from a Foundry test.
**Blocked by:** the call reverts inside the router's `unlockCallback` with **no revert data at
all**. The cause is the parameter layout. The guide at
<https://developers.uniswap.org/docs/protocols/v4/guides/swapping/swapping> builds
`IV4Router.ExactInputSingleParams` with five fields (`poolKey`, `zeroForOne`, `amountIn`,
`amountOutMinimum`, `hookData`) in both of its examples. v4-periphery `main` has six: `uint256
minHopPriceX36` sits before `hookData` (`src/interfaces/IV4Router.sol` lines 31 to 38, added to
single swaps by commit `03b2d093`, "add per-hop slippage to single swaps", PR #516, 2026-03-17).
The guide's own install line is `forge install uniswap/v4-periphery`, which fetches `main`, so
its example does not compile there: `Error (9755): Wrong argument count for struct constructor:
5 arguments given but expected 6.` A project that pins an older v4-periphery, as OpenZeppelin
uniswap-hooks v1.1.1 does, compiles the five-field form and then meets the silent revert on
chain. The npm package `@uniswap/v4-periphery` is still at 1.0.3, published 2025-07-29, before
the field existed.
**Cost:** about 10 minutes, taken from the timestamps of the commands that day. It was short only
because the first thing tried was reading `IV4Router.sol` on `main`. The revert itself gives no
lead: no selector, no string, 2,118 gas into the callback.
**Would have prevented it:** (1) update the two literals in the swapping guide and add
`minHopPriceX36: 0` with one sentence on what it limits; (2) on the deployments page, beside each
Universal Router version, name the v4-periphery commit it was built from, since the layouts it
decodes differ by version and the page does not say so (0 mentions of `minHopPriceX36`); (3) have the router revert with a named error when action parameters do
not decode, instead of empty data.
**Proof:**
- `BASE_SEPOLIA_RPC_URL=https://sepolia.base.org FOUNDRY_PROFILE=fork forge test --match-test test_UniversalRouter_2_1_2_RevertsWithNoReason_OnTheFiveFieldSwapLayout`
  passes: on a pool with no hook, the five-field encoding reverts with zero bytes of data, and the
  same swap with six fields executes at the pool's 3000-pip fee (the control). File:
  `test-fork/ReverseV4HookBaseSepolia.t.sol`.
- The guide as fetched: five-field literals at lines 184 to 190 and 266 to 272 of
  `…/llms.mdx/docs/protocols/v4/guides/swapping/swapping`; `minHopPriceX36` appears 0 times.
- The compile error was reproduced with a struct copied field for field from `main` and the
  guide's five named arguments, under solc 0.8.30.
- The pinned five-field struct: `lib/uniswap-hooks/lib/v4-periphery/src/interfaces/IV4Router.sol`
  lines 18 to 24.

### 2026-10-06 — A hook cannot name a position's owner while it is being burned, and asking reverts the burn

**Trying to:** in `afterRemoveLiquidity`, find who holds the position whose fees were just
collected, when the liquidity came through the PositionManager.
**Blocked by:** the order of two lines in `PositionManager._burn`: `_burn(tokenId)` runs before
`poolManager.modifyLiquidity(...)` (v4-periphery `src/PositionManager.sol` line 420 at pin
`7ebd04b`; line 431 on `main` at `9969eec`). So during the hook's callback the token no longer
exists and `ownerOf(tokenId)` reverts `NOT_MINTED`. A hook that calls it without a try/catch
makes every burn of a position that still holds liquidity revert, wrapped by the PoolManager. The
holder's only way out is to decrease the position to zero first, which the burn then skips
(`if (liquidity > 0)`, line 424). Minting is the other way round (token minted at line 364, liquidity added
at line 379, same pin), so the same call works there, which makes the difference easy to miss. The
guide at <https://developers.uniswap.org/docs/protocols/v4/guides/hooks/accessing-msg.sender>
covers the swap initiator only: it has 0 mentions of `ownerOf`, `PositionManager`, `tokenId`,
`salt` or burning.
**Cost:** no time lost: it was found by reading `PositionManager.sol` before the hook was written.
Written from the guide's pattern alone, the hook would have blocked burns on its pool, with no
upgrade path.
**Would have prevented it:** a section in that guide for liquidity callbacks, saying four things:
`sender` is the PositionManager; `params.salt` is `bytes32(tokenId)`; the holder is
`ownerOf(tokenId)` and exists during a mint or an increase; on a burn the token is already gone,
so the lookup must be in a try/catch and fees uncollected at burn cannot be attributed.
**Proof:**
- `forge test --match-test Burn_WithUncollectedFees` passes (2 tests): the burn goes through and
  nobody is credited.
- With the try/catch removed from `src/templates/FeesCollectedTemplate.sol`, the same two tests
  fail with the PoolManager's `WrappedError` carrying `NOT_MINTED`, and the trace shows
  `ownerOf(1) ← [Revert] NOT_MINTED`.
- `lib/uniswap-hooks/lib/v4-periphery/src/PositionManager.sol` lines 364, 379, 420 to 426.

### 2026-10-06 — On a dynamic-fee pool a fee returned without the override flag makes every swap free, and nothing reverts

**Trying to:** set the LP fee of each swap from `beforeSwap`.
**Blocked by:** nothing visible, which is the problem. A fee returned from `beforeSwap` is used
only if it carries `LPFeeLibrary.OVERRIDE_FEE_FLAG` (`0x400000`); without the flag the pool
charges its stored fee (v4-core `src/libraries/Pool.sol` lines 303 to 305), and a dynamic-fee
pool's stored fee starts at 0 (`src/libraries/LPFeeLibrary.sol` lines 52 to 53: "the initial fee
for a dynamic fee pool is 0"). The swap succeeds and the `Swap` event reports `fee = 0`. The page
<https://developers.uniswap.org/docs/protocols/v4/concepts/dynamic-fees> says a hook can
"override the LP fee for each swap" (line 45 as served) and does not name `OVERRIDE_FEE_FLAG`
(0 mentions) or say what the fee is before anything sets it.
**Cost:** no time lost: a deliberate fault injected into this repository's fee code showed it. On
a live pool it is LP revenue lost on every swap with no error to notice.
**Would have prevented it:** name the flag on that page with a one-line example
(`return (selector, ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG)`), and state that a
dynamic-fee pool charges 0 until a hook overrides the fee or calls `updateDynamicLPFee`.
**Proof:**
- In `src/templates/FeeOverride.sol`, change `return fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;` to
  `return fee;` and run `forge test --match-contract OverrideFeeTemplateTest`: tests fail with
  `a stranger's LP fee: 0 != 3000` and `member's LP fee paying in ETH: 0 != 500`. Every swap in
  those tests still executes.
- v4-core at `d153b04`: `LPFeeLibrary.sol` 52 to 53, `Hooks.sol` 263, `Pool.sol` 303 to 305.

### 2026-10-06 — `msgSender()` is on every router we tried, and it tells the truth during a swap

**Trying to:** let a hook give one swapper a different fee from another.
**Blocked by:** nothing. Universal Router 2.1.2, the earlier Universal Router and the
PositionManager on Base Sepolia all have `msgSender()` and return `address(0)` outside a swap.
During a swap, Universal Router 2.1.2 returns the real caller; that was tested for it and not for
the other two. That one function is what makes a per-swapper rule possible without trusting
`hookData`.
**Cost:** it saved the design: without it the hook has no way to know who is swapping.
**Would have prevented it:** n/a. One request: list on the deployments page which deployed
routers implement `IMsgSender`, so a hook author can choose a router to trust without probing.
**Proof:**
- `cast call <router> 'msgSender()(address)' --rpc-url https://sepolia.base.org` returns the zero
  address for `0x8702463e73f74d0b6765aBceb314Ef07aCb92650`, `0x492e6456d9528771018deb9e87ef7750ef184104`
  and `0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80`.
- `FOUNDRY_PROFILE=fork forge test --match-test test_WithUniversalRouter_2_1_2` passes: through that
  router a credential holder is charged 500 pips and anyone else 3000; with the credential not
  granted, the same test fails with `3000 != 500`.
- On chain, Base Sepolia block 47770933: the `Swap` events of transactions
  `0xe24465ee2edd82684b762bea260aee5c633b33924eb2338abfffd558bff5f267` and
  `0xa23a57b869a7470cdd48dc61c9be21be4cecc38227c1ad4ce152adaa91369969` carry `fee = 500`.

### 2026-10-06 — `feesAccrued` in the after-liquidity callbacks saved a second copy of the pool's fee math

**Trying to:** know how much in LP fees one position earned, inside a hook.
**Blocked by:** nothing. `afterAddLiquidity` and `afterRemoveLiquidity` are handed `feesAccrued`,
already worked out for the position's range, and a change of zero liquidity (a fee collection)
arrives at `afterRemoveLiquidity`.
**Cost:** it saved writing and testing per-tick fee-growth accounting in the hook.
**Would have prevented it:** n/a. One sentence in the hooks documentation that a zero-liquidity
change is routed to the *remove* callbacks would save the next reader a trip to `Hooks.sol`.
**Proof:**
- `forge test --match-test test_Collect_TellsTheHookTheOwner_AndExactlyTheFeesTheyReceived`
  passes: the amounts the hook is told equal, to the wei, what the position's owner receives.
- v4-core at `d153b04`: `src/libraries/Hooks.sol` lines 220 to 242 (a `liquidityDelta` that is not
  positive goes to `afterRemoveLiquidity`); `src/PoolManager.sol` lines 159 to 178.

---

## Summary for the feedback form

Filled in at submission, from the entries above, never from memory.

| Question the form asks | Answer, pointing at the entry that proves it |
|---|---|
| What did you build? | |
| Biggest blocker | |
| Time to first successful integration | |
| Documentation helpfulness (1–5) | |
| Support (1–5) | |
| What support was missing | |

If the form has no field for this file's URL, paste it into the free-text fields as
a `github.com` blob URL pinned to a commit SHA, and screenshot the submitted form.

---

## Feedback for other partners

| Partner | File | Status |
|---|---|---|
| Foundry (forge, cast, anvil) | [`docs/feedback/foundry.md`](docs/feedback/foundry.md) | 5 entries, 2026-10-06, each reproduced the day it was written |

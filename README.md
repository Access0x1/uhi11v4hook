# uhi11v4hook — a Uniswap v4 hook template that fails loudly

Start every v4 hook here. It has the same layout as
[Uniswap/v4-template](https://github.com/uniswap/v4-template) (`src/`, `test/`, `script/`,
OpenZeppelin `BaseHook`, hookmate), with guards added for the mistakes v4 makes **silently**.

```bash
./install-deps.sh   # libraries at pinned commits, six SHAs checked, edits refused
make gate           # pins, fmt, clean build, tests (at least one must run), manifests
```

## What makes it special: each guard and the silent failure it stops

| Guard | Where | The silent failure it stops |
|---|---|---|
| **Permissions↔address test runs first**, and was proven by sabotage | `test/Counter.t.sol` §1 | v4 reads permissions from the hook **address**, not from code. At a wrong address the callback never fires and nothing reverts. `test_WrongAddressWithoutConstructorCheck_FailsSilently` shows this happening. |
| **Official PoolManager bytecode** in tests (size checked: 24,009) | `test/utils/HookTestBase.sol` | Tests passing against a PoolManager you compiled yourself, which is not the one on chain. |
| **Pins by full SHA, verified, edits refused** | `install-deps.sh` | A tag and a branch with the same name (OZ uniswap-hooks `v1.1.1`), or a library edited in place, building something different with no error. |
| **`ffi = false`**; tests may read `context/` only | `foundry.toml` | Uniswap's template sets `ffi = true`, so any test can run shell commands on your machine. |
| **`bytecode_hash = "none"`, `cbor_metadata = false`, optimizer stated** | `foundry.toml` | A mined CREATE2 salt landing at a different address on another machine. |
| **CREATE2 deployer called directly** with `salt ++ initcode` | `script/DeployHook.s.sol` | `new Hook{salt}` sent as a plain CREATE (seen with forge 1.8.3 on Base Sepolia): the hook lands at an unmined address and its constructor reverts. |
| **The miner skips `0x91…` addresses** and addresses that already hold code | `script/DeployHook.s.sol` `mine()` | Uniswap's router does not route on its own to a hook whose address starts `0x91`. |
| **Testnets only, by table** (Sepolia, Base Sepolia, Unichain Sepolia) | `poolManagerFor()`, `script/handoff/run.sh` | No flag reaches mainnet. Any other chain id reverts before anything is sent. |
| **Guarded hand-off**: dry run by default; `LIVE=1` needs a TTY and the typed word `SEND` | `script/handoff/run.sh` | Broadcasting by accident, signing from `.env`, or deploying twice. Keys stay in `cast wallet`. |
| **`vm.chainId` set in `setUp()`** | `HookTestBase._deployV4` | A test that passes on 31337 and fails on the chain it deploys to. |
| **Manifest beside each hook, tested like code** | `context/*.json`, `test/ContextManifest.t.sol`, `context/check_context.py` | An AI reviewer (or a judge) reading a description that no longer matches the code. A changed source hash, mask or test name fails the gate. |
| **Gate requires that tests actually ran** | `Makefile` | `forge test` exits 0 with "No tests found" after a stale cache. |
| **CI on every push and PR** | `.github/workflows/gate.yml` | Uniswap's CI is `workflow_dispatch` only, so a red PR still looks green. |
| **Fuzz runs: 10,000** | `foundry.toml` | Edge amounts and ticks never being tried. A v4 swap fuzz costs about a second. |
| **No AI attribution in commits** (hook-enforced) | `.claude/hooks/` | — |

## Versus Uniswap/v4-template (read 2026-10-02)

| | Uniswap/v4-template | uhi11v4hook |
|---|---|---|
| forge-std | v1.10.0 | v1.17.0 |
| OZ uniswap-hooks | v1.1.0 | v1.1.1 |
| hookmate | Aug 2025 commit | v0.6.0 |
| solc / evm / via_ir | 0.8.30 / cancun / off | same |
| `ffi` | **true** | false |
| Pin record | git submodules + `foundry.lock` | `install-deps.sh`: SHAs checked, edits refused |
| First test | swap counts | permissions↔address, proven by sabotage |
| Deploy | `new Counter{salt}` | CREATE2 deployer called directly; result checked on chain |
| Chains | any | three testnets, by table |
| CI | manual trigger | every push and PR, the same `make gate` |
| AI-readable manifest | — | `context/`, checked against the code |

Taken from theirs unchanged: the folder layout, `BaseHook`, the example hook's callbacks
(beforeSwap, afterSwap, beforeAddLiquidity), and the MIT licence.

## Making your own hook from it

1. Copy `src/Counter.sol` → `src/YourHook.sol`. Set only the flags you implement:
   **a flag you declare but do not implement reverts every swap on the pool.** Returning a delta
   needs its own `*_RETURNS_DELTA` bit.
2. Copy the test. Put the hook's mask in `FLAGS`. Keep the permissions test first, then
   **sabotage it**: delete one flag, watch it fail, put it back. A guard you have never seen fail
   proves nothing.
3. Add one fuzz test over amounts or ticks.
4. If you touch `unlock`/`settle`/`take`/`sync`: native ETH is `address(0)`; `sync` before a native
   `settle{value:}`; refund with `call`, never `transfer`. Every delta settles.
5. Copy `context/Counter.json`, describe the hook truthfully (`doesNotGuarantee` matters most), and
   run `make gate`.
6. Deploy: `ACCOUNT=<keystore> SENDER=<address> bash script/handoff/run.sh deploy sepolia` (dry
   run), then the same with `LIVE=1`.

## Routing: which hooks Uniswap's interface reaches on its own

Every hook and template in `src/` carries a `@custom:routing` line under its title. `make gate`
checks each line against the code (`context/check_routing.py`).

Uniswap Labs' [routing allowlist](https://developers.uniswap.org/hook-allowlist) (read
2026-10-07) says a hook must apply, and is not routed to until approved, if it uses dynamic fees
or either swap returns-delta flag, or if its address starts with `0x91`. Every other hook is
allowlisted automatically.

This is about Uniswap's own interface and router. The PoolManager is permissionless on every
chain: any valid hook address can have pools, and any router that knows the pool can trade on it.

| Contract | Mask | Routing | Why |
|---|---|---|---|
| `Counter` | `0x8C0` | AUTOMATIC | static fee, no returns-delta |
| `OverrideFeeTemplate` | `0x2080` | **MANUAL** | dynamic-fee pools only |
| `GatedSwapTemplate` | `0x80` | AUTOMATIC by flags | but it reverts swaps from anyone except a named executor |
| `SwapReceiptTemplate` | `0x40` | AUTOMATIC | a swap sent without hookData leaves no receipt |
| `HookFeePotTemplate` | `0xCC` | **MANUAL** | both swap returns-delta flags |
| `FeesCollectedTemplate` | `0x500` | AUTOMATIC | no swap flag at all |
| `HolderOnlyPoolTemplate` | `0x880` | AUTOMATIC by flags | but it reverts swaps from non-holders |
| `ReverseV4Hook` | `0x25EC` | **MANUAL** | dynamic-fee pools only, and both swap returns-delta flags |

## What it does not do

- It does not make a hook safe. It makes the silent failures loud. Delta-returning hooks still need
  invariant tests and review.
- It does not deploy to mainnet. That is on purpose.
- `Counter` is an example. It moves no funds, and you replace it.

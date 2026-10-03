# Hook context manifest — schema v0

One JSON file per hook, `context/<HookName>.json`. It is what another AI reads to review the
hook without a human translating: what the hook is allowed to do, what it stores, what it
moves, what it assumes, and which test proves each property.

## The rule that makes it worth reading

A manifest that nothing checks will drift, and then it misleads the reader it was written
for. Uniswap's own hook classifier (`Uniswap/hooklist`, `.claude/prompts/classify-hook.md`)
treats a submitter's name and description as untrusted and tells its AI to ignore comments
and string literals. So every field here is one of three kinds, and the schema says which:

| Kind | Meaning | Checked by |
|---|---|---|
| **T** tested | compared against the hook or the tree on every `make gate` | `test/ContextManifest.t.sol` or `context/check_context.py` |
| **C** consistent | must agree with other fields | `test/ContextManifest.t.sol` |
| **S** stated | a human claim; a reader should verify it against the source | review only |

An empty array is a statement: `"math": []` means the hook does no fixed-point math.

## Fields

| Field | Kind | Content |
|---|---|---|
| `schemaVersion` | S | `"0"` |
| `name` | T | The Solidity contract name. At most 100 characters; none of hooklist's rejected words |
| `description` | T (form) / S (content) | What the callbacks do, in one or two sentences. At most 500 characters; no audit, safety or marketing language |
| `status` | S | The strongest of: `written`, `built`, `tested`, `deployed`, `verified`, `live-fired`. `deployed` needs an entry in `deployments` |
| `source.path` | T | Path from `hooks/`; must exist |
| `source.contract` | S | Contract name inside that file |
| `source.gitBlob` | T | `git hash-object <source.path>`: the hash of the exact source this manifest describes. Changing the hook fails the gate until the manifest is reviewed and the hash updated |
| `source.inherits` | S | Base contract and the pinned commit of its library |
| `compiler.solc` | T | Must equal `solc_version` in `foundry.toml` |
| `compiler.evmVersion`, `viaIR`, `optimizer` | S | As in `foundry.toml` |
| `permissions.mask` | T | The low 14 bits of the hook address, as a hex string. Must equal what `getHookPermissions()` declares |
| `permissions.callbacks` | T | Names of the callbacks that are on, in `Hooks.sol` bit order, returns-delta flags excluded |
| `permissions.returnsDelta` | T | `true` if any of the four returns-delta flags is on |
| `hooklist.flags` | T | The 14 flags in `Uniswap/hooklist`'s `schema.json` shape and spelling (`...ReturnsDelta`, where v4-core writes `...ReturnDelta`) |
| `hooklist.properties.dynamicFee` | S | `true` if `beforeSwap` returns a fee override or the hook calls `updateDynamicLPFee` |
| `hooklist.properties.upgradeable` | S | `true` for a proxy, a `delegatecall` to a changeable address, or `SELFDESTRUCT` |
| `hooklist.properties.requiresCustomSwapData` | S | `true` if a swap with empty `hookData` fails or misbehaves |
| `hooklist.properties.vanillaSwap` | C | Once a swap is allowed, does it execute exactly as on a hookless pool? Must be `false` with a dynamic fee, required hookData or a swap returns-delta flag; must be `true` with no swap callback |
| `hooklist.properties.swapAccess` | S | `none`, `temporal`, `allowlist`, `governance` or `other`: what gates a swap in `beforeSwap` |
| `routing.autoRoutable` | C | Whether Uniswap Labs' router picks the hook up without allowlisting. Must be `false` with a dynamic fee or a swap returns-delta flag (Uniswap support article "Routing for hooked pools", read 2026-10-01). A deployed address starting `0x91` also needs allowlisting |
| `routing.needsHookData` | C | Must equal `hooklist.properties.requiresCustomSwapData` |
| `routing.reasons` | S | One line per condition above |
| `pool` | S | What the hook binds: currencies, fee, tick spacing, or "none" |
| `state[]` | S | Every storage variable and immutable: name, type, kind, who writes, who reads |
| `transientStorage[]` | S | Every EIP-1153 slot: name, what it holds, where it is cleared |
| `math[]` | S | Every formula: the expression, its fixed-point format (Q64.96 for `sqrtPriceX96`, pips where 1e6 = 100% for fees), and the rounding direction with who it favours |
| `deltas[]` | S | Per callback: what is returned, in which currency, and who settles it. Every non-zero delta names its settlement |
| `externalCalls[]` | S | Every call out of the hook: target, function, and why the target is trusted |
| `accessControl[]` | S | Per external function: who may call it and what enforces that |
| `securityAssumptions[]` | S | What must hold for the hook to behave as described |
| `doesNotGuarantee[]` | S | What a reader might assume and must not |
| `invariants[]` | T | `statement` and `test`. Every `test` must be a test forge can run; at least one entry |
| `deployments[]` | S | `chainId`, `address`, `tx`, `verified`. Testnets only in this repo |
| `directory.tags`, `directory.integrations` | S | The same columns as Atrium's hook directory CSV |

## What never goes in a manifest

Roadmap, ideas, unreleased designs, private paths, or anything about a hook that is not in
`src/`. A manifest describes finished code and nothing else.

## Public release

When a hook moves to the public repo, `uhi-ai-context.md` is generated from its manifest and
`AGENTS.md` points a reading AI at both. Neither exists in this private repo.

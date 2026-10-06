# Feedback for Foundry

Written for the maintainers of forge, cast and anvil, in the format of the root `FEEDBACK.md`:
trying to, blocked by, cost, would have prevented it, and the proof.

Everything here happened on 2026-10-06 and was reproduced again that evening before it was
written down, with scratch projects and made-up values where a real one would be a secret.
Versions: forge, cast and anvil **1.8.3** (commit `cae51ad458f6abb64852b7709eb784352429825d`,
built 2026-09-15), macOS, solc 0.8.30. The latest release that day was v1.8.5 (2026-10-05).
**Nothing below was re-tested on 1.8.4 or 1.8.5.** Where their release notes touch a topic, the
entry says so.

## Entries

<!-- newest first -->

### 2026-10-06 — `--help` prints the live value of secrets it finds in the environment or in `./.env`

**Trying to:** read the flags of `cast source` before writing a command.
**Blocked by:** the help text itself. For a flag with an environment fallback, `--help` prints
the variable's current value: `[env: ETHERSCAN_API_KEY=<the key>]`. Foundry also loads a `.env`
from the current directory, so the value appears even when the shell never exported it; it is
enough to be standing in a project folder. Seen with `cast source --help`, `cast send --help` and
`forge verify-contract --help`. The same happens for `ETH_RPC_JWT_SECRET`, `ETH_FROM`,
`ETH_KEYSTORE_ACCOUNT` and `ETH_PASSWORD` (a file path). `--rpc-url` carries no `[env: …]` annotation in the
same output, so a way to keep a value out of the help text is already in use for one flag.
**Cost:** a live Etherscan API key printed into a captured terminal log, which then has to be
rotated.
Anything that records command output (a CI log, a shared terminal, a pasted bug report, an
assistant's transcript) receives the secret from a command that looks harmless.
**Would have prevented it:** mark the secret-bearing flags so their values are hidden in help
(clap's `hide_env_values`), at least `ETHERSCAN_API_KEY` and `ETH_RPC_JWT_SECRET`; printing
`[env: ETHERSCAN_API_KEY]` without the value loses nothing.
**Proof:** in an empty folder, with made-up values only:
```sh
printf 'ETHERSCAN_API_KEY=DUMMY_NOT_A_REAL_KEY_0001\n' > .env
cast source --help | grep 'env: ETHERSCAN'            #  [env: ETHERSCAN_API_KEY=DUMMY_NOT_A_REAL_KEY_0001]
forge verify-contract --help | grep 'env: ETHERSCAN'  #  the same
rm .env
ETH_RPC_JWT_SECRET=DUMMYJWT cast send --help | grep -c 'ETH_RPC_JWT_SECRET=DUMMYJWT'   #  1
cast send --help | grep -A3 -- '--rpc-url' | grep -c 'env'                               #  0
```

### 2026-10-06 — `forge script` set a gas limit a fifth of what Sepolia charges to create a contract, and the transaction ran out of gas

**Trying to:** deploy a 1,812-byte contract on Sepolia with `forge script … --broadcast`.
**Blocked by:** the dry run reported `Script ran successfully` and `Estimated total gas used for
script: 583304`; the broadcast was mined with **status 0, gasUsed 583,304 = gasLimit 583,304**
(transaction `0xba754ca5d4b85558703dccd8b3ec235605be2c6c4fb73a44317df705f5b902da`, block 11857240).
forge sizes the limit from its own simulation (448,695 gas, times the default 130%). The node's
`eth_estimateGas` for the same creation was 3,038,683. Sepolia charges far more for contract
creation than forge 1.8.3's EVM assumes:

| `cast estimate --create`, same sender | Sepolia | Base Sepolia | Unichain Sepolia |
|---|---|---|---|
| a contract with 0 bytes of code (`0x6100005ff3`) | 210,478 | 53,856 | 53,856 |
| 1,000 bytes (`0x6103e85ff3`) | 1,752,938 | 256,362 | 256,362 |
| 2,000 bytes (`0x6107d05ff3`) | 3,295,367 | 458,048 | 458,048 |

That is about 1,542 gas per byte of deployed code on Sepolia against about 202 on the other two,
where forge's figure was right (448,696 used). Why Sepolia differs was not looked into.
**Cost:** one failed transaction (0.000611 Sepolia ETH), a nonce, and with it the address the
deployment had been predicted at; about 10 minutes to measure and work around. Nothing in the dry
run hinted at it.
**Would have prevented it:** before broadcasting, have `forge script` ask the target node for
`eth_estimateGas` on each transaction and warn, or use the larger figure, when the node's answer
is well above the simulated one. Failing that, one line in the script documentation that the
limit comes from forge's own EVM and may be too low on a chain whose gas schedule has moved.
**Proof:**
- `cast receipt 0xba754ca5d4b85558703dccd8b3ec235605be2c6c4fb73a44317df705f5b902da --rpc-url https://ethereum-sepolia-rpc.publicnode.com`
  shows `status 0 (failed)` and `gasUsed 583304`; `cast tx <hash> gas` shows 583304.
- The table: `cast estimate --from <sender> --rpc-url <rpc> --create <code>` for the three codes on
  the three chains, read again on the evening of 2026-10-06 with the same results.
- The workaround: the same script with `--gas-estimate-multiplier 900` sent a limit of 4,038,264
  and the creation used 3,013,598, status 1 (transaction
  `0x6f4f6db631a6217365b625d06459223a26b67dc896143cdcf27ddd7626ad750a`).

### 2026-10-06 — `vm.setEnv` in one test changes what a sibling test reads, because tests of a suite run side by side in one process

**Trying to:** test a script whose `run()` reads five addresses with `vm.envAddress`, by setting
them with `vm.setEnv` in each test.
**Blocked by:** 6 of 10 tests failed with each other's values: a test that had set `CREDENTIAL` to
one address reverted on the address a neighbouring test had just written. The documentation page
<https://getfoundry.sh/reference/cheatcodes/set-env> says `setEnv` changes the environment "of the
currently running `forge` process"; it does not say that the tests of one run share that process
concurrently (the page has 0 mentions of parallel, thread or race).
**Cost:** about 10 minutes. The failures look like logic errors in the code under test, not like
a harness effect.
**Would have prevented it:** one more line in that page's "Gotchas": tests run in parallel and see
each other's `setEnv`, so give the code under test a function that takes its configuration as
arguments, or run with `--threads 1`.
**Proof:** this file, alone in a project, with forge-std:
```solidity
contract EnvRaceTest is Test {
    function _writeThenRead(string memory mine) internal {
        for (uint256 i = 0; i < 200; i++) {
            vm.setEnv("ENV_RACE_PROBE", mine);
            assertEq(vm.envString("ENV_RACE_PROBE"), mine, "read back another test's value");
        }
    }
    function test_A() public { _writeThenRead("A"); }
    function test_B() public { _writeThenRead("B"); }
    function test_C() public { _writeThenRead("C"); }
    function test_D() public { _writeThenRead("D"); }
}
```
`forge test` failed three runs out of three, with messages such as `read back another test's
value: D != A`; `forge test --threads 1` passed 4 of 4.

### 2026-10-06 — With `dynamic_test_linking` on by default, every `forge script` after a test run warns about artifacts of forge's own temporary files

**Trying to:** run a deployment script in a repository whose tests had been run.
**Blocked by:** `Warning: Detected artifacts built from source files that no longer exist. Run
`forge clean` to make sure builds are in sync with project files.`, followed by paths such as
`<project>/foundry-pp/DeployHelper74.sol`. That folder is forge's own: `forge config` shows
`dynamic_test_linking = true` in a project that does not set it, the test build writes helper
sources there and removes them, and their artifacts stay in `out/`. `forge clean` quiets the
warning only until tests are compiled again. The person about to sign a live transaction saw an
unexplained warning telling them their build was out of sync, and stopped.
**Cost:** one aborted live run and about 10 minutes to find the cause. `forge clean`, the remedy
the message names, does not last.
**Would have prevented it:** leave forge's own `foundry-pp/` sources out of that check, or say in
the warning that they are forge's. The release notes of v1.8.4 mention "Improved dynamic
test-linking and compiler-cache correctness"; whether that covers this was not tested.
**Proof:** in this repository, which sets the option to `false` in `foundry.toml`:
```sh
export FOUNDRY_DYNAMIC_TEST_LINKING=true      # forge 1.8.3's default
forge clean && forge test --match-contract TestnetCredentialRegistryTest >/dev/null
forge script script/DeployReverseV4Hook.s.sol:DeployReverseV4Hook --sig 'roundingMargin()' | grep -c 'Detected artifacts'   # 1
forge clean
forge script script/DeployReverseV4Hook.s.sol:DeployReverseV4Hook --sig 'roundingMargin()' | grep -c 'Detected artifacts'   # 0
unset FOUNDRY_DYNAMIC_TEST_LINKING            # the repository's setting: off
forge clean && forge test --match-contract TestnetCredentialRegistryTest >/dev/null
forge script script/DeployReverseV4Hook.s.sol:DeployReverseV4Hook --sig 'roundingMargin()' | grep -c 'Detected artifacts'   # 0
```
The creation code of a contract in `src/` is byte for byte the same with the option on or off.

### 2026-10-06 — `anvil --auto-impersonate` with `forge script --unlocked --broadcast` rehearsed seventeen real transactions before one was signed

**Trying to:** know, before a live run, whether each transaction of a seventeen-step script would
fit its gas limit and succeed in order.
**Blocked by:** nothing. `anvil --fork-url <rpc> --auto-impersonate`, then the unchanged script
with `--rpc-url http://127.0.0.1:<port> --sender <owner> --unlocked --broadcast`, sent all
seventeen with the limits forge would really use. Every receipt could be read afterwards.
**Cost:** it saved a failed live sequence: the rehearsal is where a limit that is too low shows up
as a failed receipt rather than as a successful simulation.
**Would have prevented it:** n/a. One caution worth a line in the docs: the rehearsal writes
`broadcast/<script>/<chain id>/run-latest.json` and its `cache/` twin exactly where a live run
writes, because the fork keeps the chain id. They have to be removed before the real run.
**Proof:** the rehearsal's seventeen receipts all had status 1 and used between 68% and 76% of
their limits; the live run that followed, on Base Sepolia in block 47770933, used the same gas to
the unit for each step (for example 449,079 for the position mint and 239,431 for the first swap,
in both).

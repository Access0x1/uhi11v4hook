#!/usr/bin/env bash
# run.sh — the ONLY way this template sends a transaction. You run it; nothing else does.
#
#   ACCOUNT=<keystore name> SENDER=<its address> bash script/handoff/run.sh <deploy|demo|deploy-reverse|deploy-registry|demo-reverse|deploy-same> <sepolia|base-sepolia|unichain-sepolia> [hook]
#
# deploy-reverse deploys ReverseV4Hook and also needs, in the environment: CREDENTIAL, CREDENTIAL_ID,
# POSITION_MANAGER, SWAP_ROUTER, TREASURY. The rates, including the 9.9% treasury share, are fixed in
# script/DeployReverseV4Hook.s.sol and cannot be set from here.
#
# demo-reverse <net> <hook> runs one real pass through a deployed ReverseV4Hook: two demo tokens, a
# pool, a position, a swap each way, the fees collected, the bonus claimed, the treasury swept. It
# needs SWAP_ROUTER, the hook's trusted router, and a sender who holds the hook's credential.
#
# deploy-registry deploys the testnet credential registry. Its issuer, the one address that can grant
# and revoke, is ISSUER if set and otherwise SENDER. It cannot be changed after deployment.
#
# deploy-same <net> <HookName> deploys one hook of src/business/ through CreateX, at the address that
# SENDER gets for that name on every chain (script/DeployBusinessHook.s.sol lists each hook's own
# settings, read from the environment). It always rehearses first, asks the NODE what the deployment
# costs, and sizes the gas limit from that answer. It refuses a second run on a chain.
#
# RPC: keyless public endpoints by default. With ALCHEMY_KEY set in YOUR shell (never in a file) the
# three testnets use Alchemy with that one key; RPC=... overrides both. The key is never printed here.
#
# Without LIVE=1 it is a dry run: forge simulates against the live chain and sends nothing.
# With LIVE=1 it signs with your Foundry keystore (`cast wallet import <name> --interactive`);
# forge asks for the password in YOUR terminal. No key, password or keyed RPC is in any file.
#
# Before anything is sent it refuses unless: the chain is one of the three testnets, the RPC
# answers with that chain id, the signer holds enough ETH, and the hook is in the state the step
# expects (no code before deploy, code before demo). Mainnet chain ids are not in the table, so
# there is no flag that reaches mainnet.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

step=${1:?deploy, demo, deploy-reverse, deploy-registry, demo-reverse or deploy-same}; net=${2:?sepolia, base-sepolia or unichain-sepolia}; hook=${3:-}
: "${ACCOUNT:?set ACCOUNT to your keystore name}" "${SENDER:?set SENDER to the address of that account}"

# Keyless public RPCs. Override with RPC=... if one is down; never paste a keyed URL into a file.
case "$net" in
  sepolia)          chain=11155111; pub=https://ethereum-sepolia-rpc.publicnode.com; alch=eth-sepolia;      min=30000000000000000;;
  base-sepolia)     chain=84532;    pub=https://sepolia.base.org;                    alch=base-sepolia;     min=1000000000000000;;
  unichain-sepolia) chain=1301;     pub=https://sepolia.unichain.org;                alch=unichain-sepolia; min=1000000000000000;;
  *) echo "STOP: $net is not a testnet this template deploys to"; exit 1;;
esac
if [ -n "${RPC:-}" ]; then rpc=$RPC; via="the RPC you set"
elif [ -n "${ALCHEMY_KEY:-}" ]; then rpc="https://$alch.g.alchemy.com/v2/$ALCHEMY_KEY"; via="Alchemy ($alch)"
else rpc=$pub; via=$pub; fi
echo "rpc: $via"

# stderr is dropped here because a failing endpoint is echoed back with its URL, key included.
live=$(cast chain-id --rpc-url "$rpc" 2>/dev/null) || { echo "STOP: the RPC did not answer. With ALCHEMY_KEY, check that $alch is enabled for that app."; exit 1; }
[ "$live" = "$chain" ] || { echo "STOP: the RPC is chain $live, expected $chain"; exit 1; }
bal=$(cast balance "$SENDER" --rpc-url "$rpc")
[ "$(python3 -c "print(int($bal >= $min))")" = 1 ] || { echo "STOP: $SENDER holds $bal wei, below $min"; exit 1; }

# GAS_MULTIPLIER (percent, optional) replaces forge's default of 130. forge sizes a transaction's gas
# limit from its OWN simulation, and a chain can charge more than forge's EVM assumes: measured
# 2026-10-06, Sepolia charges about 1,540 gas per byte of deployed code where forge assumes 200, so a
# contract creation sent with the default limit runs out of gas there. Size it from the node's own
# estimate (`cast estimate --create`), never from forge's.
gasopt=()
if [ -n "${GAS_MULTIPLIER:-}" ]; then
  case "$GAS_MULTIPLIER" in *[!0-9]*|"") echo "STOP: GAS_MULTIPLIER must be a whole number of percent"; exit 1;; esac
  [ "$GAS_MULTIPLIER" -ge 100 ] && [ "$GAS_MULTIPLIER" -le 5000 ] || { echo "STOP: GAS_MULTIPLIER $GAS_MULTIPLIER is outside 100..5000"; exit 1; }
  gasopt=(--gas-estimate-multiplier "$GAS_MULTIPLIER")
  echo "gas limit: forge's simulated gas x $GAS_MULTIPLIER%"
fi

# send is empty in a dry run. bash 3.2 (the Mac's /bin/bash) treats "${send[@]}" of an empty array as an
# unset variable under `set -u`, so every use below is written ${send[@]+"${send[@]}"}.
send=()
if [ "${LIVE:-}" = 1 ]; then
  [ -t 0 ] || { echo "STOP: a live run needs a real terminal for the password prompt"; exit 1; }
  read -r -p "Type SEND to sign and broadcast on $net: " word
  [ "$word" = SEND ] || { echo "STOP: not sent"; exit 1; }
  send=(--account "$ACCOUNT" --broadcast)
fi

echo "chain $chain | signer $SENDER | nonce $(cast nonce "$SENDER" --rpc-url "$rpc") | $([ "${LIVE:-}" = 1 ] && echo LIVE || echo "dry run")"
case "$step" in
  deploy)
    forge script script/DeployHook.s.sol:DeployHook --rpc-url "$rpc" --sender "$SENDER" ${gasopt[@]+"${gasopt[@]}"} ${send[@]+"${send[@]}"};;
  demo)
    [ -n "$hook" ] || { echo "STOP: demo needs the hook address from the deploy step"; exit 1; }
    [ "$(cast code "$hook" --rpc-url "$rpc")" != 0x ] || { echo "STOP: no code at $hook. Deploy first."; exit 1; }
    HOOK="$hook" forge script script/DeployHook.s.sol:DemoHook --rpc-url "$rpc" --sender "$SENDER" ${gasopt[@]+"${gasopt[@]}"} ${send[@]+"${send[@]}"};;
  deploy-reverse)
    : "${CREDENTIAL:?set CREDENTIAL}" "${CREDENTIAL_ID:?set CREDENTIAL_ID}" "${POSITION_MANAGER:?set POSITION_MANAGER}"
    : "${SWAP_ROUTER:?set SWAP_ROUTER}" "${TREASURY:?set TREASURY}"
    for a in "$CREDENTIAL" "$POSITION_MANAGER" "$SWAP_ROUTER"; do
      [ "$(cast code "$a" --rpc-url "$rpc")" != 0x ] || { echo "STOP: no code at $a on $net"; exit 1; }
    done
    forge script script/DeployReverseV4Hook.s.sol:DeployReverseV4Hook --rpc-url "$rpc" --sender "$SENDER" ${gasopt[@]+"${gasopt[@]}"} ${send[@]+"${send[@]}"};;
  deploy-registry)
    ISSUER=${ISSUER:-$SENDER}
    case "$ISSUER" in 0x[0-9a-fA-F][0-9a-fA-F]*) [ ${#ISSUER} -eq 42 ] || { echo "STOP: ISSUER is not an address: $ISSUER"; exit 1; };; *) echo "STOP: ISSUER is not an address: $ISSUER"; exit 1;; esac
    echo "issuer $ISSUER (permanent)"
    ISSUER="$ISSUER" forge script script/DeployTestnetCredentialRegistry.s.sol:DeployTestnetCredentialRegistry --rpc-url "$rpc" --sender "$SENDER" ${gasopt[@]+"${gasopt[@]}"} ${send[@]+"${send[@]}"};;
  demo-reverse)
    [ -n "$hook" ] || { echo "STOP: demo-reverse needs the hook address"; exit 1; }
    : "${SWAP_ROUTER:?set SWAP_ROUTER to the trusted router of the hook}"
    [ "$(cast code "$hook" --rpc-url "$rpc")" != 0x ] || { echo "STOP: no code at $hook on $net"; exit 1; }
    [ "$(cast call "$hook" 'trustedRouter(address)(bool)' "$SWAP_ROUTER" --rpc-url "$rpc")" = true ] || { echo "STOP: $SWAP_ROUTER is not the trusted router of the hook"; exit 1; }
    HOOK="$hook" SWAP_ROUTER="$SWAP_ROUTER" forge script script/DemoReverseV4Hook.s.sol:DemoReverseV4Hook --rpc-url "$rpc" --sender "$SENDER" ${gasopt[@]+"${gasopt[@]}"} ${send[@]+"${send[@]}"};;
  deploy-same)
    [ -n "$hook" ] || { echo "STOP: deploy-same needs the hook's name, for example Access0x1Hook"; exit 1; }
    [ -f "src/business/$hook.sol" ] || { echo "STOP: there is no src/business/$hook.sol"; exit 1; }
    createx=0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed
    [ "$(cast keccak "$(cast code $createx --rpc-url "$rpc" 2>/dev/null)")" = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f ] \
      || { echo "STOP: CreateX is missing or has other code on $net"; exit 1; }
    # Rehearse. forge writes the transaction it would send; nothing is signed or sent.
    HOOK="$hook" forge script script/DeployBusinessHook.s.sol:DeployBusinessHook --rpc-url "$rpc" --sender "$SENDER" > out/deploy-same.log 2>&1 \
      || { grep -vi "alchemy.com" out/deploy-same.log | tail -15; echo "STOP: the rehearsal failed"; exit 1; }
    grep -E "chain id|hook  |sender|same address|deployed hook|code size" out/deploy-same.log
    run="broadcast/DeployBusinessHook.s.sol/$chain/dry-run/run-latest.json"
    python3 -c "import json;t=json.load(open('$run'))['transactions'][0]['transaction'];open('out/deploy-same.input','w').write(t['input']);open('out/deploy-same.gas','w').write(str(int(t['gas'],16)))"
    address=$(grep "same address" out/deploy-same.log | awk '{print $NF}')
    # The node's own answer for this exact transaction: forge's simulation is not the chain's price.
    node=$(cast estimate $createx "$(cat out/deploy-same.input)" --from "$SENDER" --rpc-url "$rpc" 2>/dev/null) || { echo "STOP: the node refused to estimate this deployment"; exit 1; }
    forge_limit=$(cat out/deploy-same.gas)
    need=$(python3 -c "import math;print(max(130, math.ceil($node*1.25/($forge_limit/1.3)*100)))")
    echo "gas: the node estimates $node; forge would have sent a limit of $forge_limit; using forge's simulation x $need%"
    if [ "$node" -gt 16000000 ] && [ "${ALLOW_LARGE:-}" != 1 ]; then
      echo "STOP: $node gas may not fit in one transaction on $net. A failed deployment still pays. ALLOW_LARGE=1 to try anyway."; exit 1
    fi
    python3 context/hookmask.py "$address" | grep -E "^mask|valid for|routing by"
    if [ "${LIVE:-}" = 1 ]; then
      HOOK="$hook" forge script script/DeployBusinessHook.s.sol:DeployBusinessHook --rpc-url "$rpc" --sender "$SENDER" --gas-estimate-multiplier "$need" ${send[@]+"${send[@]}"}
      [ "$(cast code "$address" --rpc-url "$rpc" 2>/dev/null)" != 0x ] || { echo "STOP: nothing is at $address after the run"; exit 1; }
      echo "deployed $hook at $address on $net. Read it back: make mask X=$address"
    else
      echo "dry run only: nothing was signed or sent. $hook would be at $address on every chain for $SENDER."
    fi;;
  *) echo "STOP: unknown step $step"; exit 1;;
esac

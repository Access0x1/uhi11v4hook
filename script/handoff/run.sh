#!/usr/bin/env bash
# run.sh — the ONLY way this template sends a transaction. You run it; nothing else does.
#
#   ACCOUNT=<keystore name> SENDER=<its address> bash script/handoff/run.sh <deploy|demo> <sepolia|base-sepolia|unichain-sepolia> [hook]
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

step=${1:?deploy or demo}; net=${2:?sepolia, base-sepolia or unichain-sepolia}; hook=${3:-}
: "${ACCOUNT:?set ACCOUNT to your keystore name}" "${SENDER:?set SENDER to the address of that account}"

# Keyless public RPCs. Override with RPC=... if one is down; never paste a keyed URL into a file.
case "$net" in
  sepolia)          chain=11155111; rpc=${RPC:-https://ethereum-sepolia-rpc.publicnode.com}; min=30000000000000000;;
  base-sepolia)     chain=84532;    rpc=${RPC:-https://sepolia.base.org};                      min=1000000000000000;;
  unichain-sepolia) chain=1301;     rpc=${RPC:-https://sepolia.unichain.org};                  min=1000000000000000;;
  *) echo "STOP: $net is not a testnet this template deploys to"; exit 1;;
esac

live=$(cast chain-id --rpc-url "$rpc")
[ "$live" = "$chain" ] || { echo "STOP: the RPC is chain $live, expected $chain"; exit 1; }
bal=$(cast balance "$SENDER" --rpc-url "$rpc")
[ "$(python3 -c "print(int($bal >= $min))")" = 1 ] || { echo "STOP: $SENDER holds $bal wei, below $min"; exit 1; }

send=()
if [ "${LIVE:-}" = 1 ]; then
  [ -t 0 ] || { echo "STOP: a live run needs a real terminal for the password prompt"; exit 1; }
  read -r -p "Type SEND to sign and broadcast on $net: " word
  [ "$word" = SEND ] || { echo "STOP: not sent"; exit 1; }
  send=(--account "$ACCOUNT" --broadcast)
fi

echo "chain $chain | signer $SENDER | nonce $(cast nonce "$SENDER" --rpc-url "$rpc") | ${LIVE:+LIVE}${LIVE:-dry run}"
case "$step" in
  deploy)
    forge script script/DeployHook.s.sol:DeployHook --rpc-url "$rpc" --sender "$SENDER" "${send[@]}";;
  demo)
    [ -n "$hook" ] || { echo "STOP: demo needs the hook address from the deploy step"; exit 1; }
    [ "$(cast code "$hook" --rpc-url "$rpc")" != 0x ] || { echo "STOP: no code at $hook. Deploy first."; exit 1; }
    HOOK="$hook" forge script script/DeployHook.s.sol:DemoHook --rpc-url "$rpc" --sender "$SENDER" "${send[@]}";;
  *) echo "STOP: unknown step $step"; exit 1;;
esac

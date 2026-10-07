#!/usr/bin/env python3
"""Read a Uniswap v4 hook mask.

A hook's permissions are the last 14 bits of its address (v4-core Hooks.sol). This turns a mask or
an address into the callbacks it switches on, says whether the PoolManager would accept it, and
whether Uniswap's interface routes to it on its own.

  hookmask.py 0x25EC                 a mask
  hookmask.py 0x03C7...e5ec          an address (its last 14 bits are read; the 0x91 rule is checked)
  hookmask.py beforeSwap afterSwap   names to a mask
  hookmask.py --manifests            check every context/*.json: mask valid, callbacks and
                                     returns-delta agree with it, every deployed address ends in it
"""
import json
import pathlib
import re
import sys

FLAGS = [  # (bit, name) exactly as v4-core/src/libraries/Hooks.sol
    (13, "beforeInitialize"),
    (12, "afterInitialize"),
    (11, "beforeAddLiquidity"),
    (10, "afterAddLiquidity"),
    (9, "beforeRemoveLiquidity"),
    (8, "afterRemoveLiquidity"),
    (7, "beforeSwap"),
    (6, "afterSwap"),
    (5, "beforeDonate"),
    (4, "afterDonate"),
    (3, "beforeSwapReturnsDelta"),
    (2, "afterSwapReturnsDelta"),
    (1, "afterAddLiquidityReturnsDelta"),
    (0, "afterRemoveLiquidityReturnsDelta"),
]
BIT = {name: bit for bit, name in FLAGS}
PARENT = {3: 7, 2: 6, 1: 10, 0: 8}  # a returns-delta bit needs its callback's bit
ALL = (1 << 14) - 1


def names(mask):
    return [name for bit, name in FLAGS if mask >> bit & 1]


def problems(mask):
    return [
        f"{dict(FLAGS)[child]} is set without {dict(FLAGS)[parent]}"
        for child, parent in PARENT.items()
        if mask >> child & 1 and not mask >> parent & 1
    ]


def needs_allowlist(mask):
    """True when the flags alone put the hook on Uniswap Labs' manual allowlist."""
    return bool(mask & 0b1100)


def describe(text):
    value = int(text, 16)
    is_address = len(text) == 42
    mask = value & ALL
    print(f"mask 0x{mask:04X}  ({mask:014b})")
    for bit, name in FLAGS:
        print(f"  {'on ' if mask >> bit & 1 else '.  '} bit {bit:2}  0x{1 << bit:04X}  {name}")
    bad = problems(mask)
    print("valid for the PoolManager:", "no: " + "; ".join(bad) if bad else "yes")
    if mask == 0:
        print("  (no flag at all: accepted only with a dynamic-fee pool)")
    reasons = []
    if needs_allowlist(mask):
        reasons.append("a swap returns-delta flag")
    if is_address and text.lower().startswith("0x91"):
        reasons.append("the address starts 0x91")
    print("routing by Uniswap's interface:", "MANUAL (" + ", ".join(reasons) + ")" if reasons else "AUTOMATIC by flags")
    print("  a dynamic-fee pool is MANUAL too; that is the pool key's fee field, not a bit here")
    return 1 if bad else 0


def check_manifests():
    wrong = []
    files = sorted(pathlib.Path("context").glob("*.json"))
    for path in files:
        data = json.loads(path.read_text())
        perms = data.get("permissions", {})
        mask = int(perms.get("mask", "0x0"), 16)
        for problem in problems(mask):
            wrong.append(f"{path}: {problem}")
        base = [n for n in names(mask) if not n.endswith("ReturnsDelta")]
        if sorted(perms.get("callbacks", [])) != sorted(base):
            wrong.append(f"{path}: callbacks {perms.get('callbacks')} but mask says {base}")
        if bool(perms.get("returnsDelta")) != bool(mask & 0b1111):
            wrong.append(f"{path}: returnsDelta {perms.get('returnsDelta')} disagrees with mask 0x{mask:X}")
        if needs_allowlist(mask) and data.get("routing", {}).get("autoRoutable"):
            wrong.append(f"{path}: autoRoutable is true but the mask has a swap returns-delta flag")
        deployments = data.get("deployments") or []
        for deployment in deployments if isinstance(deployments, list) else []:
            address = deployment.get("address", "")
            if re.fullmatch(r"0x[0-9a-fA-F]{40}", address) and int(address, 16) & ALL != mask:
                wrong.append(f"{path}: deployed at {address}, which does not end in 0x{mask:X}")
            if address.lower().startswith("0x91") and data.get("routing", {}).get("autoRoutable"):
                wrong.append(f"{path}: deployed at an address starting 0x91, so not auto-routable")
        print(f"{path.name:28} 0x{mask:04X}  {', '.join(names(mask))}")
    for line in wrong:
        print("hookmask:", line)
    print(f"hookmask: {len(files)} manifests checked, {len(wrong)} wrong")
    return 1 if wrong or not files else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    if args == ["--manifests"]:
        sys.exit(check_manifests())
    if args[0].startswith("0x"):
        sys.exit(describe(args[0]))
    unknown = [a for a in args if a not in BIT]
    if unknown:
        print("unknown callback:", ", ".join(unknown), "| known:", ", ".join(BIT))
        sys.exit(2)
    mask = sum(1 << BIT[a] for a in set(args))
    sys.exit(describe(f"0x{mask:04X}"))

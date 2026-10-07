#!/usr/bin/env python3
"""Every hook in src/ says, in a `@custom:routing` line, whether Uniswap's interface routes to it
automatically or only after Uniswap Labs allowlists it. This checks the line against the code.

The rule, from https://developers.uniswap.org/hook-allowlist as read 2026-10-07: a hook must apply
if it uses the beforeSwap or afterSwap returns-delta flag, or dynamic fees. (An address starting
0x91 must apply too; that is a property of a deployment, not of the source, and is not checked here.)
"""
import pathlib
import re
import sys

failures = []
checked = 0
for path in sorted(pathlib.Path("src").rglob("*.sol")):
    source = path.read_text()
    if "function getHookPermissions" not in source:
        continue
    checked += 1
    manual = bool(re.search(r"SwapReturnDelta = true", source)) or "_requireDynamicFee(" in source
    expected = "MANUAL" if manual else "AUTOMATIC"
    tag = re.search(r"@custom:routing (\w+)", source)
    if not tag:
        failures.append(f"{path}: no @custom:routing line (expected {expected})")
    elif tag.group(1) != expected:
        failures.append(f"{path}: says {tag.group(1)}, the code says {expected}")

for failure in failures:
    print("routing:", failure)
if checked == 0:
    print("routing: no hooks found in src/")
    sys.exit(1)
print(f"routing: {checked} hooks checked, {len(failures)} wrong")
sys.exit(1 if failures else 0)

#!/usr/bin/env python3
"""check_context.py - the manifest checks a Solidity test cannot do.

    python3 context/check_context.py        (run from hooks/; `make context` does)

For every context/*.json:
  1. source.path exists and source.gitBlob is the hash of that exact file
     (`git hash-object`). Change the hook and this fails until the manifest is
     reviewed again and the hash updated in the same commit.
  2. every invariants[].test is the name of a test forge can run.
  3. compiler.solc equals solc_version in foundry.toml.
  4. name and description carry none of the words Uniswap/hooklist's classifier
     rejects as unverifiable, and the description fits its 500-character limit.

test/ContextManifest.t.sol checks the permissions against the hook itself.
Exit 0 only if every manifest passes every check.
"""
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# From .claude/prompts/classify-hook.md in Uniswap/hooklist, read 2026-10-01.
REJECTED_WORDS = ["official", "verified", "audited", "safe", "trusted", "premium", "best"]
MAX_NAME = 100
MAX_DESCRIPTION = 500


def run(args):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, check=True).stdout


def forge_test_names():
    listing = json.loads(run(["forge", "test", "--list", "--json"]))
    return {name for contracts in listing.values() for tests in contracts.values() for name in tests}


def pinned_solc():
    with open(os.path.join(ROOT, "foundry.toml")) as f:
        m = re.search(r'^solc_version\s*=\s*"([^"]+)"', f.read(), re.M)
    return m.group(1) if m else None


def check(path, tests, solc):
    problems = []
    with open(path) as f:
        m = json.load(f)

    src = m["source"]["path"]
    if not os.path.isfile(os.path.join(ROOT, src)):
        problems.append(f"source.path {src} does not exist")
    else:
        have = run(["git", "hash-object", src]).strip()
        if have != m["source"]["gitBlob"]:
            problems.append(f"source.gitBlob is {m['source']['gitBlob']}, but {src} hashes to {have}")

    if not m["invariants"]:
        problems.append("invariants is empty: a hook with no tested property has nothing to state")
    for inv in m["invariants"]:
        if inv["test"] not in tests:
            problems.append(f"invariants: no test named {inv['test']}")

    if m["compiler"]["solc"] != solc:
        problems.append(f"compiler.solc is {m['compiler']['solc']}, foundry.toml pins {solc}")

    if len(m["name"]) > MAX_NAME:
        problems.append(f"name is {len(m['name'])} characters, limit {MAX_NAME}")
    if len(m["description"]) > MAX_DESCRIPTION:
        problems.append(f"description is {len(m['description'])} characters, limit {MAX_DESCRIPTION}")
    for field in ("name", "description"):
        for word in REJECTED_WORDS:
            if re.search(rf"\b{word}\b", m[field], re.I):
                problems.append(f'{field} contains "{word}", which hooklist rejects as unverifiable')

    return problems


def main():
    paths = sorted(glob.glob(os.path.join(HERE, "*.json")))
    if not paths:
        print("FAIL  no manifests found in context/")
        return 1

    tests, solc = forge_test_names(), pinned_solc()
    failed = 0
    for path in paths:
        problems = check(path, tests, solc)
        label = os.path.relpath(path, ROOT)
        if problems:
            failed += 1
            print(f"FAIL  {label}")
            for p in problems:
                print(f"      {p}")
        else:
            print(f"PASS  {label}")

    print(f"{len(paths)} manifest(s) checked, {len(paths) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bash
# install-deps.sh — put the three libraries into lib/ at pinned commits, then prove it.
#
#   ./install-deps.sh
#
# lib/ is gitignored in this repo, so THIS FILE is the pin record. Each library is fetched
# by full commit SHA, never by tag or branch name: OpenZeppelin/uniswap-hooks has both a
# tag v1.1.1 (bd5287c) and a branch v1.1.1 (a5f8319), and a name can land on either.
# Pins read from the GitHub API on 2026-10-01.
#
# Safe to re-run: a library already at its pin is left alone; one at any other commit
# stops the script instead of being replaced. A library at its pin with edited files fails
# the check too (found 2026-10-01: a changed constant in v4-core passed a HEAD-only check).
set -euo pipefail
cd "$(dirname "$0")"

FORGE_STD_URL="https://github.com/foundry-rs/forge-std"
FORGE_STD_SHA="f3dae6e6ee381f25eb6a246f7da9b85c91a68219"            # v1.17.0

UNISWAP_HOOKS_URL="https://github.com/OpenZeppelin/uniswap-hooks"
UNISWAP_HOOKS_SHA="bd5287c4a9f5c22c2393f7587a9b357662916115"        # tag v1.1.1

HOOKMATE_URL="https://github.com/akshatmittal/hookmate"
HOOKMATE_SHA="ef3e9845e0b2bc9cd5810644d7d337b00c47bc75"             # v0.6.0

# What uniswap-hooks@bd5287c records for its own submodules. Not chosen here; checked here.
V4_CORE_SHA="d153b048868a60c2403a3ef5b2301bb247884d46"
V4_PERIPHERY_SHA="7ebd04b161745b75ed0c24ba2df3bc7c25f65606"
OZ_CONTRACTS_SHA="fcbae5394ae8ad52d8e580a3477db99814b9d565"

fetch_at() { # <dir> <url> <sha>
  local dir="lib/$1" url="$2" sha="$3"
  if [ -d "$dir/.git" ]; then
    local have; have="$(git -C "$dir" rev-parse HEAD)"
    if [ "$have" = "$sha" ]; then echo "ok    $dir already at ${sha:0:12}"; return 0; fi
    echo "STOP  $dir is at $have, pin is $sha. Remove $dir yourself and re-run." >&2
    exit 1
  fi
  if [ -e "$dir" ]; then
    echo "STOP  $dir exists and is not a git checkout. Remove it yourself and re-run." >&2
    exit 1
  fi
  mkdir -p "$dir"
  git -C "$dir" init --quiet
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch --quiet --depth 1 origin "$sha"
  git -C "$dir" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
  echo "new   $dir at ${sha:0:12}"
}

check() { # <dir> <sha>
  local have; have="$(git -C "$1" rev-parse HEAD 2>/dev/null || echo MISSING)"
  if [ "$have" != "$2" ]; then
    printf 'FAIL  %-52s have %s want %s\n' "$1" "$have" "$2" >&2
    FAILED=1
    return 0
  fi
  # The right commit is not enough: a file edited in place leaves HEAD where it was.
  # git status also reports a nested library that has been changed.
  local dirty; dirty="$(git -C "$1" status --porcelain 2>/dev/null | head -3)"
  if [ -n "$dirty" ]; then
    printf 'FAIL  %-52s at its pin, but has local changes:\n%s\n' "$1" "$dirty" >&2
    FAILED=1
    return 0
  fi
  printf 'PASS  %-52s %s\n' "$1" "$have"
}

fetch_at forge-std     "$FORGE_STD_URL"     "$FORGE_STD_SHA"
fetch_at uniswap-hooks "$UNISWAP_HOOKS_URL" "$UNISWAP_HOOKS_SHA"
fetch_at hookmate      "$HOOKMATE_URL"      "$HOOKMATE_SHA"

# v4-core, v4-periphery, openzeppelin-contracts, and under them permit2 and solmate.
git -C lib/uniswap-hooks submodule update --init --recursive --depth 1 --quiet

FAILED=0
check lib/forge-std                                  "$FORGE_STD_SHA"
check lib/uniswap-hooks                              "$UNISWAP_HOOKS_SHA"
check lib/hookmate                                   "$HOOKMATE_SHA"
check lib/uniswap-hooks/lib/v4-core                  "$V4_CORE_SHA"
check lib/uniswap-hooks/lib/v4-periphery             "$V4_PERIPHERY_SHA"
check lib/uniswap-hooks/lib/openzeppelin-contracts   "$OZ_CONTRACTS_SHA"

if [ "$FAILED" -ne 0 ]; then echo "pins do not match, or a library was modified; nothing in lib/ is trusted" >&2; exit 1; fi
echo "6 checked, 6 at their pins and unmodified"

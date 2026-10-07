# Hook permissions: the 14 switches

A v4 hook's permissions are not stored anywhere. The PoolManager reads them from the **last 14
bits of the hook's own address**. Each bit is one switch: on means "call me at this moment". The
number those bits make is the hook's **mask**, and it is why a hook address is mined before
deployment.

Source: `v4-core/src/libraries/Hooks.sol` at the pin (`d153b04`), lines 27-47 and 109-127.

| Bit | Value | Switch |
|---|---|---|
| 13 | `0x2000` | beforeInitialize |
| 12 | `0x1000` | afterInitialize |
| 11 | `0x0800` | beforeAddLiquidity |
| 10 | `0x0400` | afterAddLiquidity |
| 9 | `0x0200` | beforeRemoveLiquidity |
| 8 | `0x0100` | afterRemoveLiquidity |
| 7 | `0x0080` | beforeSwap |
| 6 | `0x0040` | afterSwap |
| 5 | `0x0020` | beforeDonate |
| 4 | `0x0010` | afterDonate |
| 3 | `0x0008` | beforeSwap returns delta |
| 2 | `0x0004` | afterSwap returns delta |
| 1 | `0x0002` | afterAddLiquidity returns delta |
| 0 | `0x0001` | afterRemoveLiquidity returns delta |

A mask is the sum of the switches that are on. `0x40` is afterSwap alone. `0x25EC` is
`0x2000 + 0x400 + 0x100 + 0x80 + 0x40 + 0x20 + 0x08 + 0x04`.

## Which masks are valid

`Hooks.isValidHookAddress` refuses a returns-delta switch whose callback is off: bit 3 needs bit
7, bit 2 needs bit 6, bit 1 needs bit 10, bit 0 needs bit 8. That leaves 3 of the 4 combinations
for each of those four pairs, and the other six switches are free: 3 x 3 x 3 x 3 x 64 = **5,184
valid masks** out of 16,384. (Our arithmetic from the rule; the source states the rule, not the
count.) A mask of zero is accepted only for a dynamic-fee pool.

## What the mask says about routing

Uniswap Labs' [routing allowlist](https://developers.uniswap.org/hook-allowlist) (read
2026-10-07) requires an application when bit 3 or bit 2 is on, when the pool uses a dynamic fee,
or when the address starts `0x91`. The dynamic fee is **not** a bit in the mask: it is the `fee`
field of the pool key (`0x800000`). See the README's routing table.

## Reading a mask

```bash
python3 context/hookmask.py 0x25EC                    # a mask
python3 context/hookmask.py 0x03C77a74F3ecBc519F3590F5aff405a57401e5ec   # a deployed address
python3 context/hookmask.py beforeSwap afterSwap      # names to a mask
make masks                                            # every hook in context/, checked
```

`make gate` runs the last one: every manifest's mask must be valid, agree with the callbacks and
returns-delta it lists, and every deployed address must end in it.

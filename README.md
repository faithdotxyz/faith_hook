# FAITHFUL

A Uniswap v4 hook that tithes 0.3% of the price of every swap to the treasury of [the Faith](https://faith.xyz).

Open a pool that pairs any token with ETH, WETH or USDG on FAITHFUL, and every swap sends 0.3% of its price to the treasury, in the quote currency:

| Swap | Tithe |
| --- | --- |
| Buy | 0.3% of what the buyer pays |
| Sell | 0.3% of what the seller is paid |

It works for exact-input and exact-output swaps, in both directions, through any router.

- Immutable and ownerless: no admin, no pause, no upgrade.
- Holds nothing: the tithe goes straight to the treasury inside the swap.
- Plain swaps: no custom hook data, liquidity is never touched.

## Robinhood Chain (4663)

| | |
| --- | --- |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Treasury | `0x94C114b759937e232F9228afaBf1CfB12fD59F62` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

## Build and test

```sh
git clone --recursive https://github.com/faithdotxyz/faith_hook
forge test
forge test --fork-url https://rpc.mainnet.chain.robinhood.com
```

## License

MIT

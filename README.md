# Blend v2.1 migration

This repository collects the repositories and reproducible orchestration used to deploy Blend V2.1 on localnet and Stellar public testnet.

V2.1 is a fresh deployment of the unchanged upstream Blend V2.0.0 contracts. It continues to use the existing BLND asset and V1 emitter and replaces the impaired backstop asset with a new seven-decimal 80:20 BLND:USDC Comet v1.1 LP.

The migration deploys the unchanged V2 backstop and one pool named `TestnetV2.1`, modeled directly on the `TestnetV2` pool shown by [testnet.blend.capital](https://testnet.blend.capital). On public testnet it reuses TestnetV2's XLM, USDC, wETH, and wBTC assets, live SEP-40 oracle, pool configuration, reserve order, and reserve risk parameters.

The initial deployment deliberately leaves TestnetV2.1 admin-on-ice, outside the reward zone, and with an unfunded backstop. It initializes the new Comet with 600 BLND and 6 existing TestnetV2 USDC, sends the resulting 100 LP shares to the configured wallet, and permanently locks the empty Comet controller. After funding clears the unchanged V2 threshold, `make testnet-activate-pool` activates borrowing, enrolls the pool in the reward zone, installs TestnetV2's emission split, and starts legacy-emissions accounting. The normal V1-emitter upgrade remains separate.

## Included repositories

- [`CometDEX/comet-contracts-v1`](https://github.com/CometDEX/comet-contracts-v1) (upstream `main`, Comet v1.1)
- [`Blend-V2-1/blend-ui`](https://github.com/Blend-V2-1/blend-ui)
- [`blend-capital/blend-sdk-js`](https://github.com/blend-capital/blend-sdk-js) (upstream `main`)
- [`blend-capital/blend-contracts`](https://github.com/blend-capital/blend-contracts) (upstream `main`, V1 emitter)
- [`blend-capital/blend-contracts-v2`](https://github.com/blend-capital/blend-contracts-v2) (upstream `main`)
- [`BLNT-Protocol/blend-v2.1-receiver`](https://github.com/BLNT-Protocol/blend-v2.1-receiver) (two-hop V2-to-V2.1 emitter migration receiver)
- [`BLNT-Protocol/blend-vote-contract`](https://github.com/BLNT-Protocol/blend-vote-contract)

## Clone

```sh
git clone --recurse-submodules git@github.com:BLNT-Protocol/blend-v2.1-migration.git
```

For an existing checkout:

```sh
git submodule update --init --recursive
```

Submodule commits are intentionally pinned for reproducibility. Do not use `git submodule update --remote` in a deployment checkout. Advancing a gitlink requires reviewing the new source and any affected designated WASM hashes.

## Receiver migration test

The receiver migration harness executes the optimized receiver WASM against the exact pinned unchanged V1 emitter WASM. It advances the simulated ledger through both 31-day queue periods and verifies the two-hop handoff, strict balance qualification, atomic rollback, legacy-LP return, direct-swap recovery, and burning of receiver-period BLND.

```sh
make receiver-test
```

The test is deterministic and does not interact with the shared public-testnet emitter. It is also included in the repository-wide `make test` target.

## Build and deployment

The unchanged V2 backstop, pool-factory, and pool contracts, plus the Comet V1.1 pool contract, are fetched from their official releases and accepted only after fixed SHA-256 verification. The committed V1 emitter WASM is used only to create the isolated localnet legacy fixture; public testnet resolves and verifies the emitter already administering BLND. The locally built test-oracle WASM must match its designated hash.

```sh
make build
make localnet-plan
make testnet-plan
```

Public testnet cannot mint BLND. The 600 BLND and 6 existing TestnetV2 USDC used to initialize the new Comet must come from an explicitly configured wallet. The runner validates its signing identity before creating deployment state or submitting transactions. The BLND source aliases default to the same identity.

Deploy the unfunded candidate:

```sh
BLEND_V21_WALLET_CONFIG_DIR=/path/to/stellar-config \
BLEND_V21_WALLET_IDENTITY=my-testnet-wallet \
make testnet-deploy
```

Do not start the keeper until the backstop has been funded and the pool has been separately activated and enrolled in the reward zone. Once activation succeeds, run the keeper throughout the pre-swap period so legacy backfill is checkpointed and allocated:

```sh
make testnet-activate-pool
make testnet-keeper-once
make testnet-keeper
```

Keep the scheduled keeper running throughout the pre-swap period. Immediately before `swap_backstop`, stop the scheduled keeper and run one final `make testnet-keeper-once` checkpoint. After the normal emitter swap to the deployed V2.1 backstop has completed, finalize the one-time legacy-emissions backfill and restart the keeper in normal-emissions mode:

```sh
make testnet-enable-emissions
make testnet-keeper-once
make testnet-keeper
```

`enable-emissions` is retry-safe: it accepts an already-completed drop or distribution transition and does not assume it is the first caller.

See [the system specification](docs/SYSTEM_SPEC.md) and [deployment runbook](docs/DEPLOYMENT.md) before running a mutating deployment command.

# Coupling Notes

## Active bytecode comparison

`test/Coupling.t.sol` checks active Sepolia deployment entries from `deployments.json`.
The fork test asserts bytecode exists for the active contract entries:
`registry`, `token_arb_deployer`, `futarchy_stack_deployer`, and
`uniswap_v3_liquidity_adapter`.

Two active fields are intentionally not contract bytecode:

- `proposal_impl_v5` is `null` in the manifest.
- `operator` is an EOA and is asserted to have no bytecode.

Raw runtime hashes do not compare cleanly for this deployment because the live
bytecode includes constructor immutables and Solidity metadata. The two
registry deployer contracts also embed child creation bytecode, so their runtime
contains nested Solidity/IPFS metadata hashes. `scripts/check-coupling-bytecode.js`
normalizes only those compiler/deployment-specific regions:

- constructor immutable slots, using `deployedBytecode.immutableReferences`;
- trailing Solidity CBOR metadata;
- embedded IPFS metadata hashes inside child creation bytecode literals.

After that normalization, the checker compares the remaining runtime bytes with
`cast keccak` and reads live bytecode with `cast code`.

Run the bytecode coupling check with:

```bash
RUN_SEPOLIA_FORK_TESTS=1 RUN_COUPLING_BYTECODE_FFI=1 \
  forge test --match-path test/Coupling.t.sol --ffi
```

## Current HEAD drift: stack deployer

As of `671ad3b`, the targeted bytecode coupling check is intentionally red for
`active.futarchy_stack_deployer`:

```bash
RUN_SEPOLIA_FORK_TESTS=1 RUN_COUPLING_BYTECODE_FFI=1 \
  forge test --match-contract CouplingTest --ffi -vv
```

The manifest points at Sepolia address
`0xc5d7e4e0B73de05eda367Aa16D1cc58A2c3f4A46`, whose runtime matches the
pre-`ADAPTER_REPLACEABLE` deployer. Commit `03a1fec` changed the local
`FutarchyStackDeployer` runtime by adding an `adapterReplaceable` constructor
argument and immutable. The checker reports:

- local normalized hash:
  `0xe9f51f5e4a60e106bf0803c5d5fc77fce6ee9199bb814e6bf908a0aac8148ec4`
- on-chain normalized hash:
  `0xf4e6a1f72c186d7cb2d3670a9d188ce124d78582754bdff36b2f9d3bb2ac241f`

This is real source-vs-deploy drift, not a nondeterministic artifact issue.
Do not skip or bless this mismatch. To make the coupling gate green again,
redeploy the active registry/deployer set from current source and update
`deployments.json` + `site-testnet/deployments.json`, or revert the source
change that made the local deployer bytecode differ from the active deployment.

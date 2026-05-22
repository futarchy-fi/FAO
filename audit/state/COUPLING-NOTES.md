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

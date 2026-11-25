# QuoteZero contracts

Solidity contracts, Foundry tests and the TypeScript SDK for QuoteZero on Robinhood Chain.

QuoteZero is a set of contracts around a collection of 2,222 machine NFTs. Machines are minted with USDG, revealed with a commit-reveal entropy source, and can be lit by locking QZ. Trading fees are split, converted into tokenized stocks and paid out to lit machines.

## What is here

| Path | Contents |
|---|---|
| `contracts/src` | Solidity sources: machine NFT, light forge, entropy, fee splitter, converter, reward vault, the Closing Bell dapp and its price sources |
| `contracts/test` | Foundry unit, fuzz, invariant and fork tests |
| `contracts/script` | Testnet scripts: stand-in assets, the Closing Bell dapp and its scenario |
| `contracts/lib` | Dependencies as git submodules, pinned to upstream commits |
| `deployments` | Addresses and proof records of the Robinhood Chain testnet deployments |
| `docs/CONTRACT.md` | Contract reference |
| `packages/qz-sdk` | ABIs, event topics, types, fixtures and a deployment loader |
| `SECURITY.md` | Roles, permissions and how to report a vulnerability |
| `art/logo` | Logo files |

## Build and test

You need [Foundry](https://getfoundry.sh) and Node 22.18 or newer.

```sh
git clone --recurse-submodules https://github.com/QuoteZero/qz-contracts
cd qz-contracts/contracts
forge build
forge test --no-match-path '*Fork*'
```

Fork tests need a Robinhood Chain RPC endpoint in your environment. The SDK:

```sh
cd ..
npm install
npm run test:sdk
```

## Security

Read `SECURITY.md` for the roles and permissions of each contract and for how to report a vulnerability.

## License

MIT, see `LICENSE`.

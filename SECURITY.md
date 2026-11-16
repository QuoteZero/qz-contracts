# Security policy

This policy covers the Solidity sources in `contracts/src` of this repository. It is maintained by the QuoteZero team.

## Reporting a vulnerability

Do not open a public issue or pull request for a security problem. Report it privately.

- **Channel:** a direct message to the project account on X, [@QuoteZero_](https://x.com/QuoteZero_).
- **First message:** say that you have a security report and name the contract. Leave out the details: we answer from the same account with a private way to send them.
- **Anonymous reports are accepted.** No name, identity document or email address is asked for.
- **Replies come only from that account.** Anyone who writes from another account, or asks for a seed phrase, a private key or a payment, is not us.

Please include the affected contract and function, steps to reproduce (ideally a Foundry test), and the assets involved.

If you follow this policy in good faith, test only on a local fork or a testnet, and never touch other people's funds, we will not take or request legal action against you.

## Scope

In scope: the contracts in `contracts/src`. Out of scope: the contracts under `contracts/src/testnet`, which exist only for the testnet, and the third-party code in `contracts/lib`; report issues in those upstream.

The contracts have not had an external audit. The test suite in `contracts/test` includes unit, fuzz and invariant tests.

## Roles and permissions

What each privileged address can do, as implemented in this repository. None of the contracts uses a proxy, `DELEGATECALL`, `SELFDESTRUCT` or `tx.origin`, and none has an upgrade function. The role addresses of a deployment are set in its constructor and can be read on the explorer.

| Contract | Role | Can | Cannot |
|---|---|---|---|
| `QZMachine` | owner | configure the mint once (eligibility roots and start time); set the metadata URI until it is frozen, then freeze it (irreversible, only after reveal) | change the traits, which are fixed on chain; configure the mint a second time |
| `QZMachine` | pauser | pause and unpause the mint; the mint clock stops while paused | move or burn a machine |
| `QZEntropy` | revealer | publish the next link of the committed hash chain that seeds machine reveals | choose an arbitrary seed: each link must hash to the committed previous one. If no link is published within 7 days of the hash lock, anyone can reveal a machine with seed 0 (`QZMachine.REVEAL_TIMEOUT`) |
| `QZForge` | pauser | pause and unpause new lighting | touch QZ that is already locked; the contract has no withdraw, sweep, rescue or arbitrary call |
| `QZFeeSplitter` | owner | bind the converter and the treasury once | change either recipient after binding, withdraw, or change the split of 20/27 to the converter and 7/27 to the treasury |
| `QZFeeSplitter` | treasury | claim a treasury share that could not be pushed and was parked | touch the converter share |
| `QZConverter` | owner | register the ten stock routes until they are sealed; sealing is irreversible and required before any conversion | change a route after sealing, or withdraw funds |
| `QZConverter` | pauser | pause and unpause conversion | withdraw funds |
| `QZConverter` | keeper, executor | submit price observations and run conversions inside the bounds in `QZConverter`; after 24 hours of inactivity anyone can | set an arbitrary price |
| `QZCloseBell` | calendar | create future seasons | change a season that exists, pause, upgrade or withdraw; there is no owner |
| `QZCloseBell` | anyone | 180 days after claims open, sweep the unpaid purse of a season to the treasury | sweep anything else |
| `QZBoardSource` | owner, poster | the owner replaces the poster; the poster appends prices and pauses tracks | edit a past price |
| `QZChainlinkSource` | owner | register a price feed per track until sealed | change a feed after sealing |

`QZRewardVault` has no privileged role: it is called by `QZForge` and `QZConverter`.

Trust assumptions to read before you use the contracts: reward backing depends on the stock tokens behaving as standard ERC-20 tokens; fee conversion uses a keeper and an executor that choose observation times; the Closing Bell dapp and its price sources are deployed on the testnet only.

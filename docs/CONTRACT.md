# QuoteZero contract reference

Everything downstream builds against this file, `contracts/src/interfaces/**`, `contracts/src/lib/**` and `@qz/sdk`.
Section references such as SPEC §5.1 use the numbering of the project design notes, which are not part of this repository. Tables between `GENERATED` markers are written by
`npm run gen` in `packages/qz-sdk`; do not edit them by hand. A test fails when they are stale.

## Layout

| Piece | Path |
|---|---|
| Interfaces (one per Model B contract) | `contracts/src/interfaces/IQZ*.sol` |
| Constants (every spec number) / third-party addresses / types | `contracts/src/lib/QZConstants.sol`, `QZAddresses.sol`, `QZTypes.sol` |
| Test helper: Robinhood fork | `contracts/test/utils/` |
| SDK (ABIs, event topics, read-model types, route table, fixtures, deployment loader) | `packages/qz-sdk` |
| Deployment files | `deployments/<name>.json` (`deployments/README.md`) |

Dependencies are git submodules in `contracts/lib/` pinned to exact commits (`git submodule update --init` after cloning).

| Dep | Pin |
|---|---|
| forge-std | v1.9.7 `77041d2` |
| solady | v0.1.26 `acd959a` |
| dn404 | v0.0.25 `3397cb1` |
| v4-core | v4.0.0 `e50237c` (the PoolManager deployed on Robinhood) |
| v4-periphery | `3779387` (last commit with `BaseHook`) |
| openzeppelin-contracts | v5.6.1 `5fd1781` |
| layerzero-devtools (oapp-evm, oft-evm, test helper) | `6c87e0d` (Zellic audit Sep 2025) |
| layerzero-devtools-onft-audited (onft-evm) | `3df40c8` (Paladin ONFT721 audit Aug 2024) |
| layerzero-v2 | `943ce4a` |
| layerzero-v1 | `a1fb11a` |
| solidity-bytes-utils | v0.8.4 `f4413cd` |

`foundry.toml` pins solc 0.8.26, evm cancun, `bytecode_hash = "none"` and `cbor_metadata = false` so the build is reproducible.

## Event topics

`<Contract>.<Event>` with its signature and topic0, for the six Model B contracts. Source: `modelBEventTopics` in
`@qz/sdk` (generated from the interface ABIs by `npm run gen`). The indexer maps every key to a read-model handler in
`apps/indexer/src/catalog.ts`; a new ABI event without a handler fails `tsc` there.

<!-- BEGIN GENERATED: events -->

| Contract | Event | Signature | topic0 |
|---|---|---|---|
| QZMachine | Approval | `Approval(address,address,uint256)` | `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` |
| QZMachine | ApprovalForAll | `ApprovalForAll(address,address,bool)` | `0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31` |
| QZMachine | BaseURISet | `BaseURISet(string)` | `0xf9c7803e94e0d3c02900d8a90893a6d5e90dd04d32a4cfe825520f82bf9f32f6` |
| QZMachine | HashLocked | `HashLocked(bytes32,uint64)` | `0xcc41d2d8147bde20f077d3998d9f81c26d091566f3da9de815b10cc3f29fa659` |
| QZMachine | MetadataFrozen | `MetadataFrozen()` | `0xeef043febddf4e1d1cf1f72ff1407b84e036e805aa0934418cb82095da8d7164` |
| QZMachine | MintConfigured | `MintConfigured(bytes32,bytes32,uint64,uint64,uint64,uint64)` | `0x1c25825a503ab1931f669c86496350d7dba6e78be11d4a8cbc66174a3085df78` |
| QZMachine | Minted | `Minted(address,uint256,uint8,uint256,uint256,uint256)` | `0xf073ec3c26e95df2175ed42eabced6bdc3c8e5309ad8720b02908ec7abeba610` |
| QZMachine | MintFinalized | `MintFinalized(uint256,uint64,bytes32)` | `0x7d039ff2fb4163da4f92eb720f074b2e9429dcfb1927923e10ae39a99caeb8ab` |
| QZMachine | MintWindowExtended | `MintWindowExtended(uint64,uint64)` | `0xe78a3a6275b8135d1da3537ea785f957e03468a9f677479238f74fb9492c26f0` |
| QZMachine | Paused | `Paused(address)` | `0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258` |
| QZMachine | Revealed | `Revealed(uint256,bytes32)` | `0x7d69e344e8948ee2d0ae2411f140ed9d811e9281db0368d2f77a802d9d8346f5` |
| QZMachine | RevealRearmed | `RevealRearmed(uint256)` | `0xb1aee9037873bd04a453728680da4ec68e98b3e60a97d40e2f6e24639b7d0b84` |
| QZMachine | Transfer | `Transfer(address,address,uint256)` | `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` |
| QZMachine | Unpaused | `Unpaused(address)` | `0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa` |
| QZForge | Lit | `Lit(uint256,address)` | `0x7048f2ffa93f51beb8c7790c2135b2d55cb66d8d2588168665a4388f74ff420d` |
| QZForge | Paused | `Paused(address)` | `0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258` |
| QZForge | Unpaused | `Unpaused(address)` | `0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa` |
| QZEntropy | OnionRevealed | `OnionRevealed(uint64,bytes32)` | `0x5558f580d68e2a7d062b3fb79d17ab86652f2ba93c579f371bece7fecf9d75c9` |
| QZFeeSplitter | Bound | `Bound(address,address)` | `0x0d128562eaa47ab89086803e64a0f96847c0ed3cc63c26251f29ba1aede09d4e` |
| QZFeeSplitter | Harvested | `Harvested(address,uint256,uint256,uint256)` | `0xe48bba143e2a0b557fa6f3234bd6ffc704518cc98c7de6a2385549fae27d1b75` |
| QZFeeSplitter | TreasuryShareClaimed | `TreasuryShareClaimed(address,uint256)` | `0xb5eca162cc42bbd7168526e989f6a47c72201c46518311b5cf57de47337ac6d9` |
| QZFeeSplitter | TreasuryShareParked | `TreasuryShareParked(address,uint256)` | `0xdbab5e9a73c5b5f0fcbd5c4bf16149fd605089534bf2dd5a16ee025f05dd5527` |
| QZConverter | Converted | `Converted(uint8,uint256,uint256,uint256)` | `0xb45cbdb3bd277f30ff6af610eba12aa7f36fb8b295e73843f43d816322ae17df` |
| QZConverter | EpochOpened | `EpochOpened(uint256,uint256,uint16)` | `0x7a72a98bcb78458a2c6c1ad864fb541b3177f1008a57ace42703c13b06e93a02` |
| QZConverter | EthWrapped | `EthWrapped(uint256)` | `0x0aadcfb029d96ebbf62cf29567751aee41423910b905cb671dca713c36250172` |
| QZConverter | FallbackEntered | `FallbackEntered()` | `0x2763fa60d07d95e4e8fffe8e874e9c235ed6a4fde66951f3e900d5b61768ff2e` |
| QZConverter | Paused | `Paused(address)` | `0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258` |
| QZConverter | PricePoked | `PricePoked(uint8,uint160,bool)` | `0x65ad344ef7eb8cff1333012afda03e6d901a6b22732f02f0f4a07f0f1065d7fb` |
| QZConverter | RouteSet | `RouteSet(uint8,address)` | `0xc48911b6e20c4a8b0e9fb362d3746cbfb85c0a64cf12e75c3d4442c056137e7d` |
| QZConverter | RoutesSealed | `RoutesSealed()` | `0x8b978f73eaca99332cb4c63aaaca48701bb356b32365e7e247fe9a0e65b5c370` |
| QZConverter | Unpaused | `Unpaused(address)` | `0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa` |
| QZRewardVault | Claimed | `Claimed(uint256,uint8,address,uint256)` | `0x4ef771089e4b5ef47e7c1aef7d8253a52d84d64338be1765c1b6e8ed34cb14c1` |
| QZRewardVault | ClaimFailed | `ClaimFailed(uint256,uint8,address,bytes)` | `0x2b0fdac4937d95024e14240646148815925375d6dfcf3143f00917dcf95a1b6b` |
| QZRewardVault | Registered | `Registered(uint256,uint8,uint8,bool)` | `0xae9486bad2f739544e9e769b597bb1686749b41c5353162950053c8ca0302f33` |
| QZRewardVault | RewardNotified | `RewardNotified(uint8,uint256,uint256)` | `0xa48e27bd026e7497c9f8dbc8254dceb059145b82066440463647eca5d2c19c42` |
| QZRewardVault | TrackFrozen | `TrackFrozen(uint8,bytes)` | `0x3c792dedd2778e9bc4148c2a42a23c8694a38eddd7a04dea57aaa0cec96a8d4d` |
| QZRewardVault | TrackThawed | `TrackThawed(uint8)` | `0x53dea1a8242015de784731328227de66cff12d50f3d3153b029d264a01f20683` |

<!-- END GENERATED: events -->

## REST route table

All routes are `GET`, JSON, prefix `/api/chain`. wei and uint256 values are base-10 strings, addresses are `0x` hex,
timestamps are unix seconds. Types: `@qz/sdk/types`; route table and URL builder: `@qz/sdk/api`; one JSON fixture per
response: `@qz/sdk/fixtures`.

<!-- BEGIN GENERATED: routes -->

| Route | Query | Response type | Summary |
|---|---|---|---|
| `GET /api/chain/status` | see `RouteQuery<'status'>` | `RouteResponse<'status'>` | Index head, chain clock, mint phase and pause flags |
| `GET /api/chain/mint` | see `RouteQuery<'mint'>` | `RouteResponse<'mint'>` | Mint schedule, prices, supply, volume split and the latest mints |
| `GET /api/chain/light` | see `RouteQuery<'light'>` | `RouteResponse<'light'>` | Lighting state, optionally with the machines of a wallet |
| `GET /api/chain/machines` | see `RouteQuery<'machines'>` | `RouteResponse<'machines'>` | Machine gallery, filterable by owner, tier, track, relic and lit |
| `GET /api/chain/machines/:id` | see `RouteQuery<'machine'>` | `RouteResponse<'machine'>` | One machine with its mint and reward positions |
| `GET /api/chain/rewards` | see `RouteQuery<'rewards'>` | `RouteResponse<'rewards'>` | Claimable stock rewards per (machine, track) of a wallet |
| `GET /api/chain/rewards/tracks` | see `RouteQuery<'rewardTracks'>` | `RouteResponse<'rewardTracks'>` | Per-track accumulators, frozen state and converter status |
| `GET /api/chain/fees` | see `RouteQuery<'fees'>` | `RouteResponse<'fees'>` | Harvested fees, the converter and treasury split, and the latest harvests |
| `GET /api/chain/history` | see `RouteQuery<'history'>` | `RouteResponse<'history'>` | Per-address activity feed |
| `GET /api/chain/params` | see `RouteQuery<'params'>` | `RouteResponse<'params'>` | Read-only parameter, role and pause view |

<!-- END GENERATED: routes -->

Waitlist and SIGNAL API types are off-chain and not part of this repository.

## Model B interfaces

Model B (SPEC Model B, B.1 to B.8) has six contracts. Each has one interface in `contracts/src/interfaces/`, a generated ABI under `modelBAbis` in `@qz/sdk/abis`, and its event topics under `modelBEventTopics`. Build and test them with `forge build --root contracts`. `npm run gen` in `packages/qz-sdk` regenerates the SDK side. Values come from `QZConstants.sol`: 2,222 machines, N = `LIGHT_AMOUNT` = 100,000 QZ, mint prices `PRICE_GTD` / `PRICE_FCFS` / `PRICE_PUBLIC` = 3 / 4 / 5 USDG, mint split 25% reward pot / 75% treasury, creator fee split `REWARD_PART` : `TREASURY_PART` = 20 : 7.

Who may call what (views are open to everyone and left out):

| Contract | Function | Caller |
|---|---|---|
| QZMachine | `configureMint(gtdRoot, fcfsRoot, mintStart)` | owner, once; the window lengths (`gtdWindow()`, `fcfsWindow()`, `publicWindowMax()`) are constructor immutables, 1 minute to 7 days each, 24 h / 12 h / 24 h in production |
| QZMachine | `mint(proof)` | any wallet, one per wallet, USDG approval needed; GTD and FCFS need a Merkle proof, public does not |
| QZMachine | `finalizeMint()` | anyone, once, after sold out or after the public window |
| QZMachine | `lockHash()` | anyone, once, in blocks `F + 2 ..= F + 257` (`F` = block of `finalizeMint`): stores `blockhash(F + 1)`; keeper call |
| QZMachine | `reveal()` | anyone, once, after `lockHash` and after QZEntropy revealed the next link (7 days after the lock: no link needed, seed 0) |
| QZMachine | `rearmReveal()` | anyone, only when the window passed without a lock, never after one; records a new `F`; keeper call |
| QZMachine | `setBaseURI(uri)`, `freezeMetadata()` | owner; freeze is once |
| QZMachine | `pause()`, `unpause()` | pauser (owner EOA) |
| QZMachine | `approve`, `setApprovalForAll`, `transferFrom`, `safeTransferFrom` | token owner or approved operator, standard ERC-721 |
| QZForge | `light(machineId)` | the machine's current owner, once per machine, exactly N QZ pulled and locked, no withdraw |
| QZForge | `pause()`, `unpause()` | pauser |
| QZEntropy | `reveal(index, r)` | the revealer only; `r` must hash forward to the last revealed link |
| QZFeeSplitter | `bind(converter, treasury)` | owner, once; there is no other admin function |
| QZFeeSplitter | `harvest()` | anyone; calls the Pons sweep when allowed, claims from the escrow, then sends 20/27 of the splitter's whole ETH balance after the claim (this call's claim plus any ETH sent to it since the last harvest), less any treasury share parked for a pull (`pendingTreasury`), to QZConverter and the rest to the treasury; if the treasury push fails that share is parked and the harvest still completes; reverts `NothingToHarvest` when there is nothing beyond the parked share |
| QZFeeSplitter | `claimPendingTreasury(to)` | the treasury only (`NotTreasury` otherwise); pays the parked share to `to`; reverts `NothingPending` when none is parked |
| QZConverter | `receive()` | anyone (the splitter in practice); ETH is wrapped on the next `openEpoch` |
| QZConverter | `openEpoch()` | executor; anyone in fallback mode |
| QZConverter | `convert(...)`, `convertUsdg(...)` | executor; anyone after 24 h of executor silence, with the fallback daily cap |
| QZConverter | `poke(track)` | keeper; anyone in fallback mode |
| QZConverter | `pause()`, `unpause()` | pauser; stops `openEpoch`, `convert` and `convertUsdg` |
| QZConverter | `setRoute(track, route)`, `sealRoutes()` | owner, before the seal; the seal is once |
| QZRewardVault | `register(id)` | QZForge only, from `light` |
| QZRewardVault | `notify(track, amount)` | QZConverter only, after the stock arrived |
| QZRewardVault | `claim(ids, tracks)` | the current `ownerOf` of every id; the right follows the NFT |

Reward rights attach to the machine id. The vault reads `ownerOf` at claim time, so a transfer moves unclaimed rewards with the machine.

## QZMachine and QZEntropy (Model B, B1 and B2)

`contracts/src/machine/QZMachine.sol` and `contracts/src/random/QZEntropy.sol`. Tests: `contracts/test/machine/**` and `contracts/test/random/**` (`forge test --root contracts --match-path 'test/machine/**'`).

**QZMachine constructor** (everything is immutable; the deploy script passes the converter address it precomputed, the converter itself is deployed after the machine):

`QZMachine(owner, pauser, usdg, converter, treasury, entropy, traitsHash, priceGtd, priceFcfs, pricePublic, MintWindows(gtd, fcfs, publicMax))`, where `MintWindows` is `struct { uint64 gtd; uint64 fcfs; uint64 publicMax; }` in seconds (a struct, so the constructor stays inside the stack limit of the default build).

A zero address reverts `ZeroAddress`, a zero price `ZeroAmount`. Prices are 6-decimal USDG: 3,000,000 / 4,000,000 / 5,000,000. There is no price setter, no split setter, no royalty setter, no ownership transfer and no withdraw.

**Mint schedule.** `configureMint(gtdRoot, fcfsRoot, mintStart)` (owner, once) stores `gtdEnd = mintStart + gtdWindow`, `fcfsEnd = gtdEnd + fcfsWindow`, `publicEnd = fcfsEnd + publicWindowMax`. The three window lengths are deployment-time immutables with public views (`gtdWindow()`, `fcfsWindow()`, `publicWindowMax()`), each between 1 minute and 7 days (`BadSchedule` at construction otherwise). The production values are `GTD_WINDOW` 24 h, `FCFS_WINDOW` 12 h and `PUBLIC_WINDOW_MAX` 24 h from `QZConstants`; a testnet deployment may pass shorter ones. `phase()`, `finalizeMint` and the pause extension all read the stored boundaries, so they follow whatever the deployment chose. It reverts `BadSchedule` for a zero root or a start in the past. `phase()` is `Pending` before the start (or before configuration), `Gtd`, `Fcfs`, `Public` by time, `Closed` once sold out, finalized or at `publicEnd`.

**Mint.** `mint(proof)` reverts in this order: `EnforcedPause`, `NotConfigured` / `MintNotOpen(phase)` / `SoldOut`, `AlreadyMinted(wallet)`, `NotEligible(wallet)`. In `Gtd` the proof must verify against `gtdRoot` and the price is `priceGtd`; in `Fcfs` against `fcfsRoot` and `priceFcfs`; in `Public` the proof is ignored and everyone, listed or not, pays `pricePublic`. One mint per wallet over all phases; the flag is on the wallet, so sending the machine away does not allow another mint. Leaves are `keccak256(bytes.concat(keccak256(abi.encode(wallet))))` of a `StandardMerkleTree` with leaf type `["address"]` (the Season 0 export format); `contracts/test/machine/QZMerkle.sol` builds the same trees and its roots are pinned to the JavaScript library.

Payment: the machine pulls the price from the payer straight to the two recipients, 25% to `converter` (`price * 2500 / 10000`) and the rest to `treasury`, in the mint transaction. USDG never rests on the machine. Each pull must succeed and move exactly its amount (balance check on the recipient), otherwise the mint reverts `PaymentFailed`: a paused USDG, a blocklisted payer, converter or treasury, a missing approval or balance, a token that returns false or takes a fee. State is written before the two external calls and the function is `nonReentrant`; the machine is minted without a receiver callback.

**Finalize and reveal.** `finalizeMint()` (anyone, once; sold out, or the mint clock `>= publicEnd`) closes the supply at `mintedCount` and records `entropy.revealedIndex()` as `i` and its own block number `F`. It reads no block hash: the `MintFinalized` event carries `blockHash = 0`. `lockHash()` (anyone, once) runs in blocks `F + 2` to `F + 257`, because `blockhash(F + 1)` does not exist while the finalize transaction is built and stays readable for 256 blocks after block `F + 1`. Earlier it reverts `RevealTooEarly(F + 2)`, later `RevealWindowMissed`, a zero hash reverts `ZeroBlockHash`. It stores the hash and the timestamp (`lockedHash()`, `lockedAt()`, `hashLocked()`, event `HashLocked`) and nothing can change them afterwards. `reveal()` (anyone, once) needs the lock (`HashNotLocked`) and the entropy link `i + 1` (`entropy.revealedIndex() > i`, else `EntropyNotReady(have, need)`) and sets `offset = uint256(keccak256(abi.encode(entropy.seedOf(i + 1), lockedHash))) % 2222`; it has no window of its own. Whoever finalizes, or holds the onion and so knows every seed, cannot choose the offset: the hash of block `F + 1` is unknown when the finalize transaction is sent, and once locked it cannot be redrawn, so withholding the link buys nothing. `REVEAL_TIMEOUT` (7 days after `lockedAt`): if the link is still missing, anyone may call `reveal()` and the seed is `bytes32(0)` (event `Revealed(offset, 0)`); a published link is always preferred. The onion holder therefore chooses between at most two outcomes (the real seed or seed 0), both fixed by the locked hash. `rearmReveal()` (anyone) works only when the window passed with no lock and never after a lock (`HashAlreadyLocked`, `RevealWindowOpen` while the window is open): it stores the current block as the new `F` and emits `RevealRearmed(F)`. A re-draw therefore needs every party able to call `lockHash` to stay silent for 256 blocks; one keeper calling `lockHash` from block `F + 2` closes that door. Keeper calls after `finalizeMint`: an outside keeper must call `lockHash()` at block `F + 2` (every call counts: nothing in the contract does it by itself, and a lapse of 256 blocks without a lock opens `rearmReveal`), then `reveal()` once the link is published; `rearmReveal()` only after a lapse. `traitIdOf(id) = ((id - 1 + offset) % 2222) + 1`, `traitsOf(id)` reads the packed table of `QZTraitsTable` at that trait id. The rotation is one number for the whole collection, so a transfer never changes the traits of a machine. `finalizeMint`, `lockHash`, `reveal` and `rearmReveal` are never paused.

**Block hash trust on Robinhood Chain.** The chain is an Arbitrum Orbit chain. There `blockhash(n)` is a hash of an L2 block made by the sequencer, not a hash from Ethereum, and Arbitrum's documentation says it is not a secure source of randomness. The sequencer can choose ordering, inclusion and timing around block `F + 1`, so it can influence the hash. It does not know the onion seed. Residual trust, stated plainly: if the sequencer operator and the revealer (the holder of the onion) collude, they can steer the offset. Either one alone cannot, but only under two operating rules. First, onion link `i + 1` is published only after `hashLocked()` is true (the keeper and every operator check it); until then the sequencer does not hold the seed, and once the hash is locked nothing can change it. Second, the revealer already knows its own link, so it can compute the offset from `blockhash(F + 1)` as soon as block `F + 1` exists. What stops it from redrawing is that someone else locks the hash: if nobody calls `lockHash()` within the 256-block window, `rearmReveal()` (anyone) opens a new window and a new block hash, and a revealer that stays silent can use that to redraw. An independent keeper, not run by the onion holder, must therefore call `lockHash()` at block `F + 2`. After the lock the revealer cannot redraw, and after `REVEAL_TIMEOUT` the seed is public. `block.number` follows the parent chain's block number there, so the 256-block window is 51 to 57 minutes (the real testnet run closed it at 57 minutes) and `RevealTooEarly` can last up to a parent block time.

**Pause and the mint clock.** `pause()` (pauser) stops `mint` only. It freezes the mint clock: `unpause()` moves every boundary still ahead of the freeze point (`max(pause time, mintStart)`) by the paused time (`gtdEnd`, `fcfsEnd`, `publicEnd`; event `MintWindowExtended(by, publicEnd)`), and while paused `phase()` and `finalizeMint` read the frozen clock, so a pause never shortens a phase and cannot close the supply early. A pause that starts after `publicEnd` has passed does not block `finalizeMint`. A pause has no maximum length (one pauser EOA).

**Metadata.** `tokenURI(id) = baseURI + id` (empty until the owner sets a base URI). `freezeMetadata()` needs `revealed()` and locks `setBaseURI`. `royaltyInfo` returns `(address(0), 0)`.

**QZEntropy.** `QZEntropy(revealer, onionRoot)`, no owner and no admin function. `reveal(index, r)` (revealer only) accepts `index` ahead of the last accepted link by at most `MAX_REVEAL_GAP` (1000) when `H^(index - last)(r)` equals the last accepted link, `H = keccak256` of one 32-byte word. `seedOf(k) = keccak256(abi.encode(r_k, k))`; the seed of a link the revealer skipped is derived from the next accepted link (at most `MAX_REVEAL_GAP - 1` hashes), and the seed of a link past `revealedIndex()` is zero. Errors: `NotRevealer`, `IndexNotAhead`, `GapTooLarge`, `BadReveal`.

## QZForge (B3)

`contracts/src/light/QZForge.sol`, tests in `contracts/test/light/`. Where a machine is lit: the holder locks exactly N = 100,000 QZ, once per machine, for good.

Constructor: `QZForge(token, machine, vault, owner, pauser, lightingOpensAt)`. All six are immutable, the five addresses are non-zero, `lightingOpensAt` is non-zero. There is no bind step. The vault stores this contract's address (`vault.forge()`) and this contract stores the vault's, so the deploy script computes the vault address from the deployer nonce and deploys the forge first (or the other way round); `CheckDeploy` must assert `forge.vault() == vault` and `vault.forge() == forge`.

`light(machineId)` checks, in this order: not paused (`EnforcedPause`), `block.timestamp >= lightingOpensAt` (`LightingNotOpen(opensAt)`), `ownerOf(machineId) == msg.sender` (`NotMachineOwner`; a machine that does not exist reverts with the machine's own `ERC721NonexistentToken`), traits revealed (`NotRevealed`), not lit before (`AlreadyLit`). It sets the lit flag and the count, pulls N QZ with `safeTransferFrom`, requires the balance of the forge to have grown by exactly N (`LockAmountMismatch(expected, received)`, so a fee-on-transfer or bonus token reverts instead of locking another amount), calls `vault.register(machineId)` and emits `Lit(machineId, owner)`. A reentrancy lock covers the whole call.

| Getter | Value |
|---|---|
| `litCount()` | number of lit machines |
| `isLit(id)` | that machine is lit; never goes back |
| `lockedPrincipal()` | `litCount() * N`, computed from the count and never from the token balance, so QZ sent to the forge directly does not count |
| `lightAmount()` | N |
| `lightingOpensAt()` | the time lighting opens; the converter's first epoch starts 24 hours after it (`FIRST_OPEN_EPOCH_DELAY`) |
| `token()`, `machine()`, `vault()`, `owner()`, `pauser()`, `paused()` | as constructed; `owner` is informational |

The ABI has no withdraw, release, sweep, rescue or arbitrary-call function, no `receive` or `fallback`, and the runtime code contains no `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`, `CREATE` or `CREATE2`; `contracts/test/light/QZForge.t.sol` asserts both. The pauser can pause and unpause `light`, nothing else. A pause never touches what is already locked.

### QZFeeSplitter (B4)

`contracts/src/fee/QZFeeSplitter.sol`, the creator-fee recipient of the QZ token on Pons. Constructor: `(owner, ponsFeeEscrow, ponsLaunchFactory, qzToken, ponsHook)`, all non-zero. The factory record names the splitter as the creator-fee recipient; the curve, the phase and the pool parameters are read from the factory record on every harvest. Then the owner calls `bind(converter, treasury)` once (`AlreadyBound` after that, `ZeroAddress` for a zero argument, `NotOwner` for anyone else). Extra beyond the interface: `receive()` (Pons pays with a plain ETH call; ETH sent by hand is split by the next harvest), the immutables `ESCROW`, `FACTORY`, `TOKEN`, `HOOK`, and the event `SweepSkipped(bytes reason)`.

Fee flow into the splitter (SPEC B.3). Of a 3% trade fee, Pons keeps 0.30% (30% of the 1% base fee), so 2.70% of volume reaches the splitter: 0.70% of base fee plus the 2% creator tax. `harvest()` does not tell the two parts apart: it splits the whole balance `REWARD_PART : TREASURY_PART = 20 : 7`, so 20/27 (2.00% of volume) goes to `QZConverter` as the stock-token reward pot and 7/27 (0.70% of volume) to the treasury. The 2.00% equals the creator tax only as a total; the contract does not route the creator tax on its own to the reward pot.

`harvest()`: `NotBound` before `bind`; asks Pons to sweep, claims the escrow, then splits `total`, the splitter's whole ETH balance after the claim, less a treasury share still parked (see below). ETH sent here by hand is split too, so nothing stays behind: `toConverter = total * 20 / 27` rounded down, `toTreasury = total - toConverter`, no dust; `NothingToHarvest` means that amount is zero. The ledger and the event are written before the two ETH sends; a reentrant `harvest` from a recipient reverts `Reentrancy`. There is no function that moves the creator-fee role (`transferCreatorFeeRecipient` is never called), no owner withdraw and no setter after `bind`.

Sweep robustness: the factory record is read with a bounded `staticcall` (at most 15 words copied, `FACTORY_READ_GAS` = 200,000 forwarded) and every field is range-checked by hand, so a factory that has no code, reverts, answers fewer than 15 words, answers out-of-range fields (dirty address bits, `bool` above 1, `uint8`, `uint24`, `int24` out of range) or burns gas only skips the sweep: `SweepSkipped("factory read")` is logged and the escrow is still claimed. A change of the Pons factory ABI therefore cannot stop the fee stream.

Recipient failure: the converter is a contract of this system, so if the push to it fails the whole harvest reverts `TransferFailed(converter, amount)` with nothing moved (the fee stays in the Pons escrow); the reward share is never paid anywhere else. The treasury is pushed with `TREASURY_PUSH_GAS` (100,000); if the push fails (reverts, needs more gas, burns it) the share is parked in `pendingTreasury`, `TreasuryShareParked(treasury, amount)` is logged and the harvest completes. Only the treasury can call `claimPendingTreasury(to)` (`NotTreasury` for anyone else, `ZeroAddress`, `NothingPending`); it pays the whole parked amount to `to` (so a treasury contract can forward it), and reverts `TransferFailed` if `to` refuses, leaving the share parked. `totalToTreasury` counts ETH actually delivered. The parked ETH stays in the splitter's balance and is not split again, so `totalToConverter + totalToTreasury + balance + escrow balance` always equals everything Pons credited plus ETH sent by hand.

Pons ABI used (Robinhood Chain 4663, verified contracts, read at block 119,221,300; the fork test in `contracts/test/fork` exercises `getLaunchedToken`, `sweepFees`, `balanceOf` and `claim` against the live contracts):

| Contract | Address | Call | Use |
|---|---|---|---|
| `PonsV2LaunchFactory` | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` | `getLaunchedToken(token)` returns `LaunchedToken{token, curve, deployer, creatorFeeRecipient, pairToken, graduationThreshold, poolFee, tickSpacing, creatorTaxBps, buybackEnabled, phase, sweptQuote, sweptTokens, sweptAt, exists}` | curve address, phase (0 = on the curve, 1..3 = graduating or graduated), pool key parts |
| per-launch bonding curve | `getLaunchedToken(token).curve` | `sweepFees(uint256 minBuybackTokensOut)` | before graduation; callable by the creator fee recipient or the sweep operator; credits the escrow with 70% of the 1% base fee plus 100% of the 2% creator tax |
| `MemeHook` | `0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044` | `sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut)` | after graduation; `poolId = keccak256(abi.encode(currency0, currency1, poolFee, tickSpacing, hook))`, ETH = `address(0)` sorts first |
| `PonsV2FeeEscrow` | `0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e` | `balanceOf(recipient)`, `claim()` | `claim()` pays the caller its whole native balance (`NoBalance` at zero, so the splitter checks `balanceOf` first) and credits nothing else |

A creator may sweep only when no internal swap is needed. After graduation, swap fees paid in QZ (a buy of QZ with ETH takes its fee in QZ) wait for Pons' own operator to convert them: the creator call then reverts `InternalSwapRequiresOperator`. The splitter does not fail on that: it logs `SweepSkipped` and still claims what the escrow holds, so the pot waits, it is not lost (SPEC B.8). Anyone watching can see whether the operator has swept. Not covered on a live graduated pool: the post-graduation sweep path is tested against the mock hook only (no graduated ETH launch was available to fork at the pinned block); the pool-id formula is checked against Uniswap v4 `PoolKey.toId()`.

Testnet stand-in: `contracts/script/testnet/MockPons.sol` (`MOCK_PonsFactory`, escrow, token, curve, hook; testnet and tests only, never imported from `src/`). `new MOCK_PonsFactory(splitter, protocolFeeRecipient, sweepOperator)` deploys the whole mock with the splitter as creator-fee recipient; the splitter address is precomputed from the deployer nonce (`vm.computeCreateAddress` / `CREATE`). Same signatures and fee model as the functions above (1% base fee, 2% creator tax on the ETH side, 30% of the base fee to the protocol).

## QZConverter and QZRewardVault in Model B (B5)

Code: `contracts/src/reward/`. `QZRoyaltySplitter` is gone; the splitter of Model B is `QZFeeSplitter` (B4).

**Constructors (arguments only, no wiring call).**

- `QZConverter(Config)` with `owner, pauser, keeper, executor, weth, usdg, v3Factory, v3Router, poolManager, vault, lightingOpensAt`. `lightingOpensAt` is the time lighting opens, fixed at deployment and never 0 (the constructor reverts `ZeroAmount`); the first allowed `openEpoch()` is `firstEpochAt = lightingOpensAt + FIRST_OPEN_EPOCH_DELAY` (24 h). The keeper liveness clock starts at `lightingOpensAt`, the executor clock at `firstEpochAt`. A testnet that passes `block.timestamp - 24 hours` opens the first epoch at once, but it also starts the keeper clock 24 h in the past: the converter is in fallback mode from the first block until the keeper pokes once, so poke before relying on normal mode.
- `QZRewardVault(forge, machine, converter)`. `QZMachine -> QZConverter -> QZRewardVault -> QZForge` is a ring of constructor arguments; B7 breaks it by predicting the CREATE addresses (the converter address before `QZMachine`).

**Pots.** The converter's reward pot is three kinds of balance it holds: the ETH the splitter sends (`receive()`), WETH and USDG (the 25% mint seed). `openEpoch()` wraps all held ETH with `IWETH9.deposit` (`EthWrapped`), then splits the unassigned WETH and the unassigned USDG equally over the tracks with a lit standard machine (relics never make a track active). `EpochOpened(wethAmount, usdgAmount, activeTracks)` carries the amounts assigned. Each track has a WETH pot and a USDG pot (`trackPot(track)` returns both; `totalTrackWeth`, `totalTrackUsdg`). Division remainders and funds that arrive later stay unassigned and join the next epoch. `unassignedPot()` is balance minus assigned pots (saturating at 0), `potBalance()` is the raw balances. With nothing to assign the executor's call is a heartbeat; with no lit machine at all it reverts `NoLitMachines`.

**Conversions.** `convert(track, wethIn, minUsdgOut, minStockOut, deadline)` spends the WETH pot: WETH to USDG on the v3 pool (floor 97% of the 10 min TWAP), then USDG to stock on the v4 pool (floor 97% of the median). `convertUsdg(track, usdgIn, minStockOut, deadline)` spends the USDG pot through the second leg only. Its size is converted to WETH at the v3 TWAP (rounded up) and checked against `maxChunk` and the fallback daily cap, so the USDG pot cannot be pushed through a pool faster than the WETH pot; `usdgChunkLimit(track)` is the largest `usdgIn`. Both end with `QZRewardVault.notify` and `Converted(track, wethIn, usdgOut, stockOut)` (`wethIn` is 0 for `convertUsdg`). A call larger than its pot reverts `PotTooSmall(track, want, have)`; a track that holds nothing reverts `TrackNotActive`. The pot is debited before any external call.

**Liveness and oracle spacing.**

- Executor activity is a `convert` or `convertUsdg` of at least `fallbackDailyCap / 32` WETH (the fallback minimum chunk). `openEpoch` is not activity, so an executor that only heartbeats `openEpoch`, or converts dust, cannot keep the fallback off while pots sit unconverted: 24 h without a real conversion opens the fallback to everyone (daily cap per track). A quiet period with nothing to convert also opens it; that costs nothing, since a fallback caller can only convert existing pots inside the cap.
- `poke` keeps a minimum spacing against the newest observation of the track: 60 s in normal mode, 5 min in fallback mode (`TooEarly(notBefore)`). Nine observations then span at least 8 minutes, so a keeper cannot set the median with nine pokes in one transaction; the 9-observation rule inside 30 minutes stays satisfiable (up to 30 spaced observations fit) and the keeper's 3 minute mean poke interval is unaffected.
- Accepted risk: `pause()` has no expiry. One pauser EOA can stop `openEpoch`, `convert`, `convertUsdg` and the fallback until it unpauses. The pause cannot move assets; it only delays conversion.

**Vault.** `register(id)` is callable by the Forge only (`NotForge`); it reads `traitsOf` from the machine, which reverts before the reveal, so a machine cannot be lit blind. `notify` is callable by the converter only. `claim` needs `ownerOf(id) == msg.sender` per id; a failing stock token (blocklist, pause, burn) freezes only its own track. A machine lit after a `notify` gets nothing from it.

**What the testnet mocks (B7) must provide for the converter.**

- `v3Factory.getPool(weth, usdg, fee)` returns a pool with `observe(uint32[])` ticks, and a router whose `exactInputSingle` (the 7-field struct) pulls WETH with `transferFrom` and pays USDG.
- A WETH9 with `deposit()`.
- For each of the ten routes an initialised v4 USDG/stock pool with liquidity, `hooks = 0`, fee at most 1,000,000, `route.maxChunk <= 0.5 ether`, `fallbackDailyCap <= 0.05 ether` and at most `maxChunk * 32`.
- Stock tokens with `transfer` and `transferFrom`.

## Constants cross-check

Value generated from `QZConstants.sol`; the NatSpec quotes the spec section. `contracts/test/C0Constants.t.sol` asserts
the relations between them (tiers sum, fee splits, E == X0*S/(Y0-S) within 1 wei, graduation price == final curve
price, hook flags).

<!-- BEGIN GENERATED: constants -->

| Constant | Value | Spec section (NatSpec) |
|---|---|---|
| `TOTAL_MACHINES` | `2222` | B.4: machine ids are 1..2222, the NFT supply cap. |
| `STANDARD_MACHINES` | `2220` | B.4 tiers: 1200 + 650 + 280 + 90 standard machines. |
| `RELIC_COUNT` | `2` | B.4: relics "Origin Wire" #2221..#2222 (trait slots; the reveal rotation decides which token holds them). |
| `TRACK_COUNT` | `10` | B.1: ten reward tracks (stock tokens). Order: NVDA, AAPL, TSLA, GME, SPY, PLTR, NFLX, RDDT, MSTR, SPCX. |
| `MACHINES_PER_TRACK` | `222` | 2220 standard machines / 10 tracks = 222 per track. |
| `TIER_RELIC` | `0` | Tier ids 1..4 = I Ticker, II Relay, III Endpoint, IV Zero Desk. Tier 0 = relic. |
| `TIER_I_PER_TRACK` | `120` | Per track: 120 / 65 / 28 / 9. |
| `WEIGHT_TIER_I` | `10` | Integer reward weights: tier I = 10, II = 15, III = 25, IV = 40 (1x / 1.5x / 2.5x / 4x times 10). |
| `TOTAL_STANDARD_WEIGHT` | `32350` | Total standard weight 3235 in 1x units (1200*1 + 650*1.5 + 280*2.5 + 90*4) = 32350 in the integer weights. |
| `RELIC_SHARE_BPS` | `1000` | Each track's distribution gives 10% to the relics, split equally over the 2 relic slots (5% each). Unlit relic slots fall back to the standard machines. `rel = amount * 10% * R / 2`. |
| `ACC_PRECISION` | `1000000000000000000000000000000000000` | Vault accumulator scale P = 1e36. |
| `USDG_DECIMALS` | `6` | B.4: USDG on Robinhood Chain has 6 decimals. |
| `PRICE_GTD` | `3000000` | B.4 prices, USDG with 6 decimals. These are the defaults the deploy script passes to the three immutable `QZMachine` constructor arguments; the contract reads its own immutables, never these. |
| `GTD_WINDOW` | `86400` | B.4 windows: GTD 24 h, FCFS 12 h, public until sold out and at most 24 h (60 h total). |
| `MINT_REWARD_BPS` | `2500` | B.4 mint split, in the payment transaction: 25% to `QZConverter` (first reward pot), 75% to the treasury. |
| `MAX_PER_WALLET` | `1` | B.4: one mint per wallet across all phases. |
| `REVEAL_MODULUS` | `2222` | B.4 reveal: `offset = keccak256(seed, lockedHash) mod 2222`. |
| `MACHINE_ROYALTY_BPS` | `0` | B.4: royalty 0%. |
| `QZ_TOTAL_SUPPLY` | `1000000000000000000000000000` | B.1 / B.5: Pons fair launch, 1 billion QZ with 18 decimals. |
| `LIGHT_AMOUNT` | `100000000000000000000000` | B.5: N = 100,000 QZ (0.01% of supply) locked per machine, exactly, once, forever. |
| `CREATOR_TAX_BPS` | `200` | B.3: creator tax T = 2% (200 bps). Pons base fee 1% with a 30% protocol share (both read from Pons at deploy by runbook B7; if `protocolFeeShareBps` is not 3000 these are recomputed before deploy). |
| `REWARD_PART` | `20` | B.3: what reaches the `QZFeeSplitter` is split 20:7 (reward : treasury), sealed in its constructor. `reward = total * 20 / 27` rounded down, `treasury = total - reward`, so no dust stays behind. |
| `MAX_REVEAL_GAP` | `1000` | B.4 / B.6 trimmed `QZEntropy`: one reveal may skip at most this many onion links (verified by hashing `index - lastIndex` times). Bounds the gas of a reveal. |
| `FIRST_OPEN_EPOCH_DELAY` | `86400` | B.5: first `openEpoch()` is allowed 24 h after lighting opens (no race to light first). |
| `OPEN_EPOCH_INTERVAL` | `60` | Later `openEpoch()` interval 60 s. |
| `CONVERT_FLOOR_BPS` | `9700` | §3.2 leg 1: `minUsdgOut >= 97% x TWAP 10 min` of the v3 WETH/USDG pool. |
| `MAX_SPOT_DEVIATION_BPS` | `300` | §3.2 leg 2 floor: `97% x usdgIn / median`; `convert` reverts if spot deviates > 3% from the median. |
| `MIN_OBSERVATIONS` | `9` | §3.2 normal mode: median of >= 9 observations within the last 30 min. |
| `KEEPER_POKE_MEAN_INTERVAL` | `180` | §3.2 normal mode: keeper pokes at undisclosed random times, mean 3 minutes (off-chain schedule). |
| `FALLBACK_SILENCE` | `86400` | §3.2 fallback: keeper silent > 24 h makes `poke` permissionless; same window makes `convert` permissionless. |
| `FALLBACK_MIN_OBSERVATIONS` | `25` | §3.2 fallback median: >= 25 observations spaced >= 5 min, spanning >= 2 h. |
| `DEFAULT_MAX_CHUNK` | `500000000000000000` | §3.2 `maxChunk[track]` default 0.5 ETH (NFLX 0.1 ETH); sealed. |
| `DEFAULT_FALLBACK_DAILY_CAP` | `50000000000000000` | §3.2 `fallbackDailyCap[track]` 0.05 ETH/day, sealed. |

<!-- END GENERATED: constants -->

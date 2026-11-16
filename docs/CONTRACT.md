# QuoteZero contract reference

Everything downstream builds against this file, `contracts/src/interfaces/**`, `contracts/src/lib/**` and `@qz/sdk`.
Spec numbers come from the project spec (the 16 Nov changes on top). Tables between `GENERATED` markers are written by
`npm run gen` in `packages/qz-sdk`; do not edit them by hand. A test fails when they are stale.

## Layout

| Piece | Path |
|---|---|
| Interfaces (one per SPEC §5.1 contract, R1 + R2) | `contracts/src/interfaces/IQZ*.sol` |
| Constants (every spec number) / addresses / types / reference curve math | `contracts/src/lib/QZConstants.sol`, `QZAddresses.sol`, `QZTypes.sol`, `QZCurveMath.sol` |
| Test helpers: Robinhood fork, LayerZero 3-endpoint (EIDs 30416 / 30339 / 30184) | `contracts/test/utils/` |
| SDK (ABIs, event catalog, read-model types, route table, fixtures, curve math, deployment loader) | `packages/qz-sdk` |
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

Two LayerZero devtools pins are deliberate: SPEC §5.1 asks for audit commits, and the OApp/OFT audit and the ONFT
audit are different commits. `foundry.toml` pins solc 0.8.26, evm cancun, `bytecode_hash = "none"` and
`cbor_metadata = false` so the adapter codehash (`EXPECTED_ADAPTER_CODEHASH`) is reproducible.

## Event catalog

`contract`, `event`, fields, when it is emitted, the indexer table (Postgres schema `chain`, owned by X1) and the
screens that read data derived from it. Source: `packages/qz-sdk/src/events.ts` (typed `Record<EventKey, EventMeta>`, so
a new ABI event without a row fails `tsc`).

<!-- BEGIN GENERATED: events -->

| Contract | Event | Fields | Emitted when | Indexer table | Screens |
|---|---|---|---|---|---|
| QZCore | Approval | address indexed owner, address indexed spender, uint256 value | ERC-20 allowance set. | `chain.approvals` | - |
| QZCore | Hardwired | address indexed owner, uint256 indexed ticketId, uint256 indexed machineId | Owner hardwires a revealed ticket: exactly 1 QZ and that ticket are burned and the machine NFT is minted to the owner; the machine id leaves the draw pool for good. | `chain.machines` | machines, rewards, history |
| QZCore | Paused | address by | Pauser (the single owner EOA) calls pause(). | `chain.pauses` | admin |
| QZCore | TicketDissolved | uint256 indexed ticketId, uint64 nonce | A pending ticket is burned because the owner no longer holds the whole QZ unit (sell/transfer) before reveal. | `chain.tickets` | machines, history |
| QZCore | TicketMinted | address indexed owner, uint256 indexed ticketId, uint64 nonce, uint64 epoch | A wallet crossing whole-QZ units mints a pending ticket (DN-404 mirror mint); `nonce`/`epoch` seed the reveal. | `chain.tickets` | machines, history |
| QZCore | TicketRevealed | uint256 indexed ticketId, uint256 indexed machineId | QZEntropy delivers the epoch seed and the ticket resolves to a machine id (callback `onTicketRevealed`). | `chain.tickets` | machines, history |
| QZCore | Transfer | address indexed from, address indexed to, uint256 value | Any QZ movement: curve buy/sell, pool swap, wallet transfer, mint/burn of the 1-QZ dark-mirror ticket units. | `chain.qz_transfers` | token, history |
| QZCore | Unpaused | address by | Pauser (the single owner EOA) calls unpause(). | `chain.pauses` | admin |
| QZDarkMirror | Approval | address indexed owner, address indexed approved, uint256 indexed tokenId | ERC-721 approval on a ticket. | `chain.approvals` | - |
| QZDarkMirror | ApprovalForAll | address indexed owner, address indexed operator, bool approved | ERC-721 operator approval on tickets. | `chain.approvals` | - |
| QZDarkMirror | Transfer | address indexed from, address indexed to, uint256 indexed tokenId | ERC-721 mirror of ticket units: emitted on every ticket mint, burn or move (always via QZCore). | `chain.tickets` | machines |
| QZEntropy | EpochRevealed | uint64 indexed epoch, bytes32 seed | Keeper reveals the next hash-onion preimage; the epoch seed becomes final and pending tickets can resolve. | `chain.epochs` | machines, admin |
| QZEntropy | EpochRolled | uint64 indexed from, uint64 indexed to | Epoch counter advances (120 s cadence, or rollover after a missed reveal window). | `chain.epochs` | machines, admin |
| QZEntropy | MachineReturned | uint256 indexed machineId, uint64 epoch | A revealed machineId returns to the draw pool because its ticket dissolved after the epoch closed (balance fell below a whole QZ); usable from `epoch`. Hardwiring never returns a machine: a hardwired id leaves the pool permanently (I3). | `chain.machines` | machines, history |
| QZMachine | Approval | address indexed owner, address indexed approved, uint256 indexed tokenId | ERC-721 approval on a machine. | `chain.approvals` | - |
| QZMachine | ApprovalForAll | address indexed owner, address indexed operator, bool approved | ERC-721 operator approval on machines. | `chain.approvals` | - |
| QZMachine | MetadataFrozen | - | Owner freezes the base URI forever (one-time). | `chain.metadata_events` | admin |
| QZMachine | Transfer | address indexed from, address indexed to, uint256 indexed tokenId | Machine NFT mint (hardwire) or ordinary owner-to-owner transfer. Home machines are never burned (I3); a machine sent over the bridge is locked in the adapter, not burned. | `chain.machine_transfers` | machines, rewards, circuit, history |
| QZCurve | BuysPaused | address by | Owner pauses curve buys. | `chain.pauses` | trade, admin |
| QZCurve | BuysUnpaused | address by | Owner resumes curve buys. | `chain.pauses` | trade, admin |
| QZCurve | CurveBuy | address indexed buyer, address indexed recipient, uint256 ethIn, uint256 qzOut, uint256 fee, uint8 phase | ETH -> QZ on the bonding curve (direct or via router). `phase` is the Phase at purchase time. | `chain.curve_trades` | trade, token, history |
| QZCurve | CurveSell | address indexed seller, address indexed recipient, uint256 qzIn, uint256 ethOut, uint256 fee | QZ -> ETH on the bonding curve. | `chain.curve_trades` | trade, token, history |
| QZCurve | Graduated | uint256 wethToPool, uint256 qzToPool, uint160 sqrtPriceX96, uint128 liquidity | The curve reached 12 ETH: pool initialised, all raised WETH and the 888.8 QZ reserve sent to the lock, curve closed. | `chain.curve_lifecycle` | trade, token, admin |
| QZCurve | PotPulled | address indexed sink, uint256 amount | The converter (reward pot) or the treasury pulls its accumulated curve fees. | `chain.pot_pulls` | admin |
| QZCurve | Started | uint64 launchAt | Owner calls start(launchAt): F0 begins at launchAt. | `chain.curve_lifecycle` | trade, admin |
| QZHook | FeeTaken | address indexed swapper, bool isBuy, uint256 wethFee, uint256 feeBps | Every pool swap that pays the 3% hook fee (taken in WETH, afterSwap). | `chain.hook_fees` | token, history |
| QZHook | Paused | address by | Pauser (the single owner EOA) calls pause(). | `chain.pauses` | token, admin |
| QZHook | PotPulled | address indexed sink, uint256 amount | The converter (reward pot) or the treasury pulls accumulated hook fees. | `chain.pot_pulls` | admin |
| QZHook | Unpaused | address by | Pauser (the single owner EOA) calls unpause(). | `chain.pauses` | token, admin |
| QZRouter | Swapped | address indexed sender, address indexed recipient, bool isBuy, uint256 ethAmount, uint256 qzAmount, bool viaCurve | A router trade settled: curve while open, v4 pool after graduation (`viaCurve` tells which). | `chain.router_swaps` | trade, token, history |
| QZConverter | Converted | uint8 indexed track, uint256 wethIn, uint256 usdgOut, uint256 stockOut | One track chunk converted WETH -> USDG -> stock and notified to the vault. | `chain.converter_epochs` | rewards, admin |
| QZConverter | EpochOpened | uint256 amount, uint16 activeTracks | Keeper opens a conversion epoch (first 24 h after launch, then every 60 s): WETH pot split across active tracks. | `chain.converter_epochs` | rewards, admin |
| QZConverter | FallbackEntered | - | The oracle path failed its window: the converter switches to the capped fallback route. | `chain.converter_epochs` | rewards, admin |
| QZConverter | Paused | address by | Pauser (the single owner EOA) calls pause(). | `chain.pauses` | rewards, admin |
| QZConverter | PotsPulled | uint256 fromHook, uint256 fromCurve, uint256 fromCircuitRedirect | Converter pulled the reward pots from hook, curve and the circuit redirect in one call. | `chain.pot_pulls` | admin |
| QZConverter | PricePoked | uint8 indexed track, uint160 sqrtPriceX96, bool byKeeper | A price observation recorded (keeper or anyone) for the median / fallback window of a track. | `chain.converter_epochs` | admin |
| QZConverter | RouteSet | uint8 indexed track, address stock | Owner configures a stock route before routes are sealed. | `chain.converter_config` | admin |
| QZConverter | RoutesSealed | - | Owner seals the routes (one-time, irreversible). | `chain.converter_config` | admin |
| QZConverter | Unpaused | address by | Pauser (the single owner EOA) calls unpause(). | `chain.pauses` | rewards, admin |
| QZRewardVault | Claimed | uint256 indexed id, uint8 indexed track, address indexed to, uint256 amount | A machine owner claims stock tokens for (machine, track). | `chain.reward_claims` | rewards, history |
| QZRewardVault | RewardNotified | uint8 indexed track, uint256 amount, uint256 accPerWeight | Converter delivers stock tokens for a track; the per-weight accumulator grows. | `chain.reward_notifications` | rewards |
| QZRewardVault | TrackFrozen | uint8 indexed track, bytes reason | A stock token blocked a transfer: only that track is frozen, `reason` is the revert data. | `chain.reward_tracks` | rewards, admin |
| QZRewardVault | TrackThawed | uint8 indexed track | A later transfer on a frozen track succeeded: the track is claimable again. | `chain.reward_tracks` | rewards, admin |
| QZCircuit | CircuitClaimed | uint256 indexed id, uint256 indexed week, address indexed to, uint256 amount | A completer claims its WETH share for a week. | `chain.circuit_claims` | circuit, history |
| QZCircuit | CircuitCompleted | uint256 indexed id, uint256 indexed week | Both round trips are done in a week: the machine counts for that week. | `chain.circuit_completions` | circuit, history |
| QZCircuit | Hop | uint256 indexed id, uint32 eid, uint256 week | A machine completes one LayerZero leg of the weekly Circuit (Ink or Base round trip). | `chain.circuit_hops` | circuit, history |
| QZCircuit | PotCarried | uint256 indexed fromWeek, uint256 indexed toWeek, uint256 amount | A week with no completers rolls its pot into the next week. | `chain.circuit_weeks` | circuit |
| QZCircuit | PotPulled | uint256 indexed week, uint256 amount | The Circuit pulls its WETH pot from the hook (weekly accounting). | `chain.pot_pulls` | circuit, admin |
| QZCircuit | PotRedirected | uint256 amount | After the 180 day redirect delay unclaimed pot is sent to the converter reward flow. | `chain.circuit_weeks` | circuit, admin |
| QZCircuit | WeekSettled | uint256 indexed week, uint256 pot, uint256 completed, uint256 perMachine | A week closes: pot and completer count fixed, `perMachine` is the WETH each completer can claim. | `chain.circuit_weeks` | circuit |
| QZLiquidityLock | Compounded | uint256 amount | The keeper calls compound(min, max): the LP share of hook fees (0.50% of swap volume, 1/6 of the 3% hook fee) is added back to the locked position. | `chain.lock_events` | token, admin |
| QZLiquidityLock | Seeded | uint128 liquidity | Graduation: full-range liquidity minted into the pool and locked forever. | `chain.lock_events` | token, admin |
| QZMachineAdapter | Activated (R2) | - | Anyone calls activate() (one-time) after the owner renounced ownership and cleared the LayerZero delegate; sends stay disabled until then (I7). | `chain.pauses` | admin |
| QZMachineAdapter | MachineDeparted (R2) | uint256 indexed id, uint32 dstEid | A machine is locked in the adapter and its ONFT sent to a spoke chain. | `chain.bridge_transfers` | circuit, machines, history |
| QZMachineAdapter | MachineReturned (R2) | uint256 indexed id, uint32 srcEid | A machine ONFT comes back from a spoke chain and is released from the adapter. | `chain.bridge_transfers` | circuit, machines, history |
| QZMachineAdapter | ONFTReceived (R2) | bytes32 indexed guid, uint32 srcEid, address indexed toAddress, uint256 tokenId | LayerZero delivered a machine from a spoke chain. | `chain.bridge_transfers` | circuit, machines |
| QZMachineAdapter | ONFTSent (R2) | bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 tokenId | A machine was sent to a spoke chain through LayerZero. | `chain.bridge_transfers` | circuit, machines |
| QZMachineAdapter | Paused (R2) | address by | Pauser (the single owner EOA) calls pause(). | `chain.pauses` | admin |
| QZMachineAdapter | Unpaused (R2) | address by | Pauser (the single owner EOA) calls unpause(). | `chain.pauses` | admin |
| QZTokenAdapter | Activated (R2) | - | Anyone calls activate() (one-time) after the owner renounced ownership and cleared the LayerZero delegate; sends stay disabled until then (I7). | `chain.pauses` | admin |
| QZTokenAdapter | OFTReceived (R2) | bytes32 indexed guid, uint32 srcEid, address indexed toAddress, uint256 amountReceivedLD | QZ arrived from a spoke chain and was released from the adapter. | `chain.bridge_transfers` | token, history |
| QZTokenAdapter | OFTSent (R2) | bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 amountSentLD, uint256 amountReceivedLD | QZ was locked in the adapter and sent to a spoke chain. | `chain.bridge_transfers` | token, history |
| QZTokenAdapter | Paused (R2) | address by | Pauser (the single owner EOA) calls pause(). | `chain.pauses` | admin |
| QZTokenAdapter | Unpaused (R2) | address by | Pauser (the single owner EOA) calls unpause(). | `chain.pauses` | admin |
| QZMachineONFT | Activated (R2) | - | Anyone calls activate() (one-time) after the owner renounced ownership and cleared the LayerZero delegate; sends stay disabled until then (I7). | `chain.pauses` | admin |
| QZMachineONFT | Approval (R2) | address indexed owner, address indexed approved, uint256 indexed tokenId | ERC-721 approval on a spoke machine. | `chain.approvals` | - |
| QZMachineONFT | ApprovalForAll (R2) | address indexed owner, address indexed operator, bool approved | ERC-721 operator approval on spoke machines. | `chain.approvals` | - |
| QZMachineONFT | ONFTReceived (R2) | bytes32 indexed guid, uint32 srcEid, address indexed toAddress, uint256 tokenId | LayerZero delivered a machine to the spoke chain. | `chain.bridge_transfers` | circuit, machines |
| QZMachineONFT | ONFTSent (R2) | bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 tokenId | A machine left the spoke chain through LayerZero. | `chain.bridge_transfers` | circuit, machines |
| QZMachineONFT | Paused (R2) | address by | Pauser (the single owner EOA) calls pause(). | `chain.pauses` | admin |
| QZMachineONFT | Transfer (R2) | address indexed from, address indexed to, uint256 indexed tokenId | Spoke machine mint (arrival), transfer or burn (departure). | `chain.bridge_transfers` | circuit, machines |
| QZMachineONFT | Unpaused (R2) | address by | Pauser (the single owner EOA) calls unpause(). | `chain.pauses` | admin |
| QZTokenOFT | Activated (R2) | - | Anyone calls activate() (one-time) after the owner renounced ownership and cleared the LayerZero delegate; sends stay disabled until then (I7). | `chain.pauses` | admin |
| QZTokenOFT | Approval (R2) | address indexed owner, address indexed spender, uint256 value | ERC-20 allowance on spoke QZ. | `chain.approvals` | - |
| QZTokenOFT | OFTReceived (R2) | bytes32 indexed guid, uint32 srcEid, address indexed toAddress, uint256 amountReceivedLD | LayerZero delivered QZ to the spoke chain. | `chain.bridge_transfers` | token, history |
| QZTokenOFT | OFTSent (R2) | bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 amountSentLD, uint256 amountReceivedLD | QZ left the spoke chain through LayerZero. | `chain.bridge_transfers` | token, history |
| QZTokenOFT | Paused (R2) | address by | Pauser (the single owner EOA) calls pause(). | `chain.pauses` | admin |
| QZTokenOFT | Transfer (R2) | address indexed from, address indexed to, uint256 value | Spoke QZ mint (arrival), transfer or burn (departure). | `chain.bridge_transfers` | token |
| QZTokenOFT | Unpaused (R2) | address by | Pauser (the single owner EOA) calls unpause(). | `chain.pauses` | admin |

<!-- END GENERATED: events -->

## REST route table

All routes are `GET`, JSON, prefix `/api/chain`. wei and uint256 values are base-10 strings, addresses are `0x` hex,
timestamps are unix seconds. Types: `@qz/sdk/types`; route table and URL builder: `@qz/sdk/api`; one JSON fixture per
response: `@qz/sdk/fixtures`.

<!-- BEGIN GENERATED: routes -->

| Route | Query | Response type | Screens | Summary |
|---|---|---|---|---|
| `GET /api/chain/status` | see `RouteQuery<'status'>` | `RouteResponse<'status'>` | trade, admin | Index head, phase, pause flags |
| `GET /api/chain/curve` | see `RouteQuery<'curve'>` | `RouteResponse<'curve'>` | trade, token | Curve state: sold, reserve, price, progress, limits |
| `GET /api/chain/curve/trades` | see `RouteQuery<'curveTrades'>` | `RouteResponse<'curveTrades'>` | trade, token | Curve trades, newest first, optional account filter |
| `GET /api/chain/tickets` | see `RouteQuery<'tickets'>` | `RouteResponse<'tickets'>` | machines | Pending and revealed tickets of a wallet |
| `GET /api/chain/machines` | see `RouteQuery<'machines'>` | `RouteResponse<'machines'>` | machines | Machine gallery, filterable by owner, tier, track, relic, hardwired |
| `GET /api/chain/machines/:id` | see `RouteQuery<'machine'>` | `RouteResponse<'machine'>` | machines, rewards, circuit | One machine with rewards and Circuit state |
| `GET /api/chain/rewards` | see `RouteQuery<'rewards'>` | `RouteResponse<'rewards'>` | rewards | Claimable stock rewards per (machine, track) of a wallet |
| `GET /api/chain/rewards/tracks` | see `RouteQuery<'rewardTracks'>` | `RouteResponse<'rewardTracks'>` | rewards, admin | Per-track accumulators and frozen state |
| `GET /api/chain/circuit/leaderboard` | see `RouteQuery<'circuitLeaderboard'>` | `RouteResponse<'circuitLeaderboard'>` | circuit | Weekly Circuit leaderboard and pot |
| `GET /api/chain/circuit/claimable` | see `RouteQuery<'circuitClaimable'>` | `RouteResponse<'circuitClaimable'>` | circuit | Unclaimed Circuit WETH per (machine, week) of a wallet |
| `GET /api/chain/token` | see `RouteQuery<'token'>` | `RouteResponse<'token'>` | token | Post-graduation token stats |
| `GET /api/chain/history` | see `RouteQuery<'history'>` | `RouteResponse<'history'>` | history | Per-address activity feed |
| `GET /api/chain/params` | see `RouteQuery<'params'>` | `RouteResponse<'params'>` | admin | Read-only parameter and pause view |

<!-- END GENERATED: routes -->

Waitlist and SIGNAL API types are off-chain and not part of this repository.

## Curve rounding rules (SPEC §1.6)

State is `(sold, reserve)`. Reference code: `QZCurveMath.sol` and `packages/qz-sdk/src/curve.ts` (same vectors in
`test/C0CurveMath.t.sol` and `test/curve.test.ts`).

- `reserveAt(s) = ceil(K / (Y0 - s)) - X0`. `Y0` is rounded up to the wei, so `reserveAt(S) == E == 12 ether` exactly and I9 (`reserve <= E`) holds.
- Buy with net `n = ethIn - fee`: `s' = Y0 - ceil(K / (X0 + e + n))`. QZ rounds down, the reserve becomes `e + n` exactly.
- Fee is `ceil(gross * 100 / 10000)` on the ETH side of both buy and sell. Reward share is `floor(fee * 75 / 100)`, treasury takes the rest.
- Sell: `e' = reserveAt(s - q)`, gross release `e - e'`, ETH rounds down. A buy/sell round trip never profits (fuzzed).
- A buy that would pass `S` is cut at `S` and the surplus is refunded. Phase limits (F0/F1/F2) revert, they never truncate.
- `quoteBuyExactQz` returns the minimal ETH for at least `qzOut`; the curve may deliver up to a few hundred wei of QZ more.

## Additions beyond SPEC §5.1 (decided in C0, spec was silent)

- QZCore: `onTicketRevealed` (entropy-only callback, emits `TicketRevealed`), `grantPoolTransfer(toPool, fromPool)` (hook-only, T13: transient per-direction QZ allowance of the PoolManager, granted from the exact QZ delta of the canonical pool's swaps and of the lock's liquidity changes), `setBaseURI` / `freezeMetadata` forwarding to QZMachine.
- QZLiquidityLock: `compound(sqrtPriceMinX96, sqrtPriceMaxX96)` is keeper-only (`keeper` is a sealed constructor argument), reverts when the canonical pool was swapped earlier in the same transaction (`QZHook.pullLpPot` reverts `PoolSwappedThisTransaction`) and when the pool price is outside the window; `QZHook.authorizeLockSettlement(int128)` is lock-only.
- Curve events carry `recipient`: `CurveBuy(buyer, recipient, ethIn, qzOut, fee, phase)`, `CurveSell(seller, recipient, qzIn, ethOut, fee)`.
- Extra events: `Started`, `BuysPaused` / `BuysUnpaused`, `PotPulled`, converter `PotsPulled` / `RouteSet` / `RoutesSealed`, vault `TrackThawed`.
- QZHook and QZConverter are `IQZPausable` (SPEC §4.2 pause scope includes swap through the hook and convert).
- F0 Merkle leaf: OpenZeppelin StandardMerkleTree with leaf type `["address"]`, value = `recipient`.
- Circuit: week 0 starts at `launchAt`; `claim` and `claimCircuit` take parallel (id, track/week) arrays; completion is order-free via a flags bitmask (bit0 Ink round trip, bit1 Base round trip).
- Pool key: LP fee 0 (the hook takes 3%), tickSpacing 60, full range (-887220, 887220).
- `claimFor` is omitted (spec: later stage). Spec stock addresses (§3.1) are copied as written and not verified against an official directory.

## Constants cross-check

Value generated from `QZConstants.sol`; the NatSpec quotes the spec section. `contracts/test/C0Constants.t.sol` asserts
the relations between them (tiers sum, fee splits, E == X0*S/(Y0-S) within 1 wei, graduation price == final curve
price, hook flags).

<!-- BEGIN GENERATED: constants -->

| Constant | Value | Spec section (NatSpec) |
|---|---|---|
| `TOTAL_SUPPLY` | `4444000000000000000000` | §1.3 invariant I1: `totalSupply + totalHardwired * 1e18 == 4444e18`. |
| `UNIT` | `1000000000000000000` | §1.2: one whole QZ = one dark ticket = one potential machine. |
| `TOTAL_MACHINES` | `4444` | §1.3: machine ids are 1..4444. |
| `STANDARD_MACHINES` | `4440` | §1.3 tiers: 2400 + 1300 + 560 + 180 standard machines. |
| `RELIC_COUNT` | `4` | §1.3: relics "Origin Wire" #4441..#4444. |
| `TRACK_COUNT` | `10` | §3.1: ten reward tracks (stock tokens). Order: NVDA, AAPL, TSLA, GME, SPY, PLTR, NFLX, RDDT, MSTR, SPCX. |
| `MACHINES_PER_TRACK` | `444` | §1.3: 4440 standard machines / 10 tracks = 444 per track. |
| `TIER_RELIC` | `0` | §1.3 tier table, tier ids 1..4 = I Ticker, II Relay, III Endpoint, IV Zero Desk. Tier 0 = relic. |
| `TIER_I_PER_TRACK` | `240` | §1.3 per track: 240 / 130 / 56 / 18. |
| `WEIGHT_TIER_I` | `10` | §2.5 integer reward weights: tier I = 10, II = 15, III = 25, IV = 40 (1x / 1.5x / 2.5x / 4x times 10). |
| `TOTAL_STANDARD_WEIGHT` | `64700` | §1.3: total standard weight 6470 in 1x units (2400*1 + 1300*1.5 + 560*2.5 + 180*4) = 64700 in the integer weights of §2.5 (x10). |
| `RELIC_SHARE_BPS` | `1000` | §1.3 / §2.5: each track's distribution gives 10% to the relics, split equally over the 4 relic slots (2.5% each). Unlit relic slots fall back to the standard machines. `rel = amount * 10% * R / 4`. |
| `ACC_PRECISION` | `1000000000000000000000000000000000000` | §2.5 accumulator scale P = 1e36. |
| `HOOK_FEE_BPS` | `300` | §1.4 post-graduation swap fee: 3% of the WETH side, buy and sell. Taken in the hook's afterSwap. |
| `HOOK_REWARD_BPS` | `200` | §1.4 split of the 3%, in bps of swap volume: 2.00 / 0.50 / 0.25 / 0.25. Sum = HOOK_FEE_BPS. |
| `CURVE_FEE_BPS` | `100` | §1.4 curve phase fee: 1% of the ETH side on buy and sell (pump.fun `fee_basis_points = 100`). |
| `CURVE_REWARD_BPS` | `75` | §1.4 split of the curve fee, in bps of trade volume: 0.75 reward pot / 0.25 treasury. Sum = CURVE_FEE_BPS. |
| `ROYALTY_BPS` | `500` | §1.4 QZMachine royalty (ERC-2981): 5% = 4% reward pot + 1% treasury. |
| `F0_DURATION` | `1800` | §1.5 F0 "Handshake": 0..30 min after `launchAt`, waitlist Merkle proof required. |
| `F1_END` | `7200` | §1.5 F1 "Open Wire": 30..120 min after `launchAt`, public. |
| `F0_MAX_PER_WALLET` | `2000000000000000000` | §1.5 F0: max 2 QZ per wallet cumulative (no separate per-tx limit; the wallet limit binds). |
| `F1_MAX_PER_TX` | `2000000000000000000` | §1.5 F1: max 2 QZ per tx, max 10 QZ per wallet cumulative (includes F0 purchases). |
| `F2_MAX_PER_TX` | `20000000000000000000` | §1.5 F2: max 20 QZ per tx, no per-wallet limit. |
| `CURVE_SUPPLY` | `3555200000000000000000` | §1.6 S = QZ sold on the curve: 3555.2 QZ (80% of 4444). |
| `POOL_SUPPLY` | `888800000000000000000` | §1.6 G = QZ reserved for the pool: 888.8 QZ (= 4444 - S). |
| `X0` | `4000000000000000000` | §1.6 X0 = virtual ETH reserve: 4 ETH. |
| `Y0` | `4740266666666666666667` | §1.6 Y0 = S^2 / (S - G), exact: S^2 / (S - G) = 4740.26666...e18 wei. The wei value is rounded UP (...666.67 -> ...667). Rounding up makes the reserve at s = S exactly E (12 ether): with the floor (...666) `reserveAt(S)` would be E + 1 wei and violate I9 `reserveEth <= E`. Relations (proved in test/C0Constants.t.sol): E == X0*S/(Y0-S) within 1 wei, pool price E/G == final curve price (X0+E)/(Y0-S) within 1e-21 relative. |
| `CURVE_K` | `18961066666666666666668000000000000000000` | §1.6 K = X0 * Y0, the constant product. |
| `TARGET_ETH` | `12000000000000000000` | §1.6 E = graduation target: 12 ETH of real reserve at s = S. I9 cap for `reserveEth`. |
| `POOL_LP_FEE` | `0` | C0 decision (spec silent): LP fee 0; the 3% is taken by the hook (§1.4). |
| `POOL_TICK_SPACING` | `60` | C0 decision (spec silent): tickSpacing 60 so full range is [-887220, 887220]. |
| `HOOK_FLAGS` | `10436` | §5.1 QZHook: beforeInitialize, beforeAddLiquidity, beforeSwap, afterSwap + afterSwap return delta. |
| `EPOCH_DURATION` | `120` | §4.3 step 2: epoch = 2 minute window on `block.timestamp`. |
| `REVEAL_ROLLOVER` | `3600` | §4.3 step 5: a missing `reveal(e)` after 1 hour rolls the queue to the next open epoch. |
| `ONION_LENGTH` | `262800` | §4.3 step 1: onion length N ~ 1 year of epochs: 365 days / 120 s. |
| `FIRST_OPEN_EPOCH_DELAY` | `86400` | §2.5: first `openEpoch()` is allowed 24 h after `launchAt`. |
| `OPEN_EPOCH_INTERVAL` | `60` | §2.5: later `openEpoch()` interval 60 s (Quotrons style). |
| `CONVERT_FLOOR_BPS` | `9700` | §3.2 leg 1: `minUsdgOut >= 97% x TWAP 10 min` of the v3 WETH/USDG pool. |
| `MAX_SPOT_DEVIATION_BPS` | `300` | §3.2 leg 2 floor: `97% x usdgIn / median`; `convert` reverts if spot deviates > 3% from the median. |
| `MIN_OBSERVATIONS` | `9` | §3.2 normal mode: median of >= 9 observations within the last 30 min. |
| `KEEPER_POKE_MEAN_INTERVAL` | `180` | §3.2 normal mode: keeper pokes at undisclosed random times, mean 3 minutes (off-chain schedule, ops unit K1). |
| `FALLBACK_SILENCE` | `86400` | §3.2 fallback: keeper silent > 24 h makes `poke` permissionless; same window makes `convert` permissionless. |
| `FALLBACK_MIN_OBSERVATIONS` | `25` | §3.2 fallback median: >= 25 observations spaced >= 5 min, spanning >= 2 h. |
| `DEFAULT_MAX_CHUNK` | `500000000000000000` | §3.2 `maxChunk[track]` default 0.5 ETH (NFLX 0.1 ETH); sealed. [INFERENCE in spec, recomputed in C5] |
| `DEFAULT_FALLBACK_DAILY_CAP` | `50000000000000000` | §3.2 `fallbackDailyCap[track]` proposal 0.05 ETH/day, sealed. [INFERENCE in spec, recomputed in C5] |
| `CIRCUIT_WEEK` | `604800` | §4.4 weekly Circuit. C0 decision (spec silent on the origin): week 0 starts at `launchAt`. |
| `REDIRECT_DELAY` | `15552000` | §4.2: `redirectPot()` allowed `launchAt` + 180 days if no active adapter. |
| `EID_ROBINHOOD_TESTNET` | `40451` | §4.2 / §8 Tahap 2 testnet EIDs: Robinhood 40451 (chain 46630), Ink Sepolia 40358 (763373), Base Sepolia 40245 (84532). |
| `MAX_UNITS_PER_MESSAGE` | `10` | §5.1 / §5.2: at most 10 whole QZ (tickets) per OFT message, gas bound for the escrow release. |
| `OFT_SHARED_DECIMALS` | `6` | §5.2 shared decimals 6 (default), local 18 -> bridge minimum 0.000001 QZ. |
| `LZ_CONFIRMATIONS` | `30` | §5.2 confirmations 30 each way. |
| `LZ_MSG_TYPE_SEND` | `1` | §5.2 enforced options: msgType SEND = 1 (SEND_AND_CALL = 2 not opened in R1/R2 phase 1). |
| `GAS_ONFT_HOME_TO_SPOKE` | `120000` | §5.2 enforced lzReceive gas per path. |
| `RATE_LIMIT_QZ` | `200000000000000000000` | §5.2 rate limiter example: 200 QZ / 1 h per EID and 50 machines / 1 h per EID. [INFERENCE, calibrate on testnet] |

<!-- END GENERATED: constants -->

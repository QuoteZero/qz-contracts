// Typed fixtures, one per route response (the compiler checks them against the read-model types).
// `npm run gen` writes them to fixtures/<route>.json; test/fixtures.test.ts fails if those files drift.
import type { RouteName, RouteResponse } from './api.ts';
import { TRACKS, UNIT, WEIGHT_TIER_II } from './constants.ts';
import { priceAt, progress, quoteBuy } from './curve.ts';

// What the fixtures share is computed once, so a number that appears in two responses cannot disagree.
/** The one curve trade of the fixtures: 1 ETH into an empty curve (the curve, its trade list, the token volume and the history all read it). */
const TRADE_ETH = UNIT;
const trade = quoteBuy({ sold: 0n, reserve: 0n }, TRADE_ETH);
const boughtQz = (trade.qzOut * 100n) / UNIT;
/** The history line the indexer writes for that trade: whole QZ and two places, rounded down. */
const TRADE_DETAIL = `Bought ${boughtQz / 100n}.${String(boughtQz % 100n).padStart(2, '0')} QZ`;
/**
 * The machine of the fixtures: machine 39, the first Relay on NVDA in metadata/traits.json. This file is bundled into the web app's
 * sample mode, so it cannot import the 2,222-row table; e2e/fixtures-consistency.test.ts (npm test) checks every field of M, and
 * every other machine field in this file, against that table.
 */
const M = { id: 39, tier: 2, numeral: 'II', relic: false, track: 0, ticker: TRACKS[0], weight: Number(WEIGHT_TIER_II) } as const;
const PENDING = '1250000000000000';
/** The Circuit pot of week 0 after its one finisher took part. */
const CIRCUIT_AMOUNT = '2500000000000000';
/** The machine finished its circuit in week 0: the machine page and the leaderboard row say the same. */
const CIRCUIT = { week: 0, flags: 3, completed: true } as const;

export const fixtures = {
  status: {
    "chainId": 4663,
    "indexedBlock": 1200,
    "headBlock": 1203,
    "indexedAt": 1763300000,
    "chainTime": 1763299990,
    "phase": "F1",
    "launchAt": 1763290000,
    "buysPaused": false,
    "corePaused": false,
    "graduated": false,
    "epoch": 42
  },
  curve: {
    "phase": "F1",
    "launchAt": 1763290000,
    "sold": trade.next.sold.toString(),
    "reserve": trade.next.reserve.toString(),
    "price": priceAt(trade.next.sold, trade.next.reserve).toString(),
    "progressBps": Number(progress(trade.next.sold)),
    "graduated": false,
    "limits": {
      "maxPerTx": "2000000000000000000",
      "maxPerWallet": "10000000000000000000"
    },
    "totals": {
      "trades": 1,
      "ethVolume": TRADE_ETH.toString(),
      "feesPaid": trade.fee.toString()
    }
  },
  curveTrades: {
    "items": [
      {
        "txHash": "0xabababababababababababababababababababababababababababababababab",
        "blockNumber": 1199,
        "timestamp": 1763299900,
        "side": "buy",
        "account": "0x1111111111111111111111111111111111111111",
        "recipient": "0x1111111111111111111111111111111111111111",
        "ethAmount": TRADE_ETH.toString(),
        "qzAmount": trade.qzOut.toString(),
        "fee": trade.fee.toString(),
        "phase": "F1"
      }
    ],
    "nextCursor": null
  },
  tickets: {
    "owner": "0x1111111111111111111111111111111111111111",
    "tickets": [
      {
        "ticketId": 3,
        "owner": "0x1111111111111111111111111111111111111111",
        "status": "pending",
        "epoch": 43,
        "revealEta": 96,
        "machineId": null,
        "mintedAt": 1763299900
      },
      {
        "ticketId": 2,
        "owner": "0x1111111111111111111111111111111111111111",
        "status": "revealed",
        "epoch": 41,
        "revealEta": null,
        "machineId": M.id,
        "mintedAt": 1763299700
      }
    ],
    "skipNft": false
  },
  machines: {
    "items": [
      {
        "id": M.id,
        "tier": M.tier,
        "relic": M.relic,
        "track": M.track,
        "ticker": M.ticker,
        "owner": "0x1111111111111111111111111111111111111111",
        "eid": 30416,
        "hardwired": true
      }
    ],
    "nextCursor": null,
    "total": 2222
  },
  machine: {
    "id": M.id,
    "tier": M.tier,
    "relic": M.relic,
    "track": M.track,
    "ticker": M.ticker,
    "owner": "0x1111111111111111111111111111111111111111",
    "eid": 30416,
    "hardwired": true,
    "weight": M.weight,
    "traits": [
      {
        "name": "Tier",
        "value": M.numeral
      },
      {
        "name": "Track",
        "value": M.ticker
      }
    ],
    "imageUrl": null,
    "hardwiredAt": 1763299950,
    "rewards": [
      {
        "machineId": M.id,
        "track": M.track,
        "ticker": M.ticker,
        "stock": "0x3333333333333333333333333333333333333333",
        "pending": PENDING,
        "claimed": "0",
        "frozen": false
      }
    ],
    "circuit": {
      "week": CIRCUIT.week,
      "completed": CIRCUIT.completed,
      "flags": CIRCUIT.flags
    }
  },
  rewards: {
    "owner": "0x1111111111111111111111111111111111111111",
    "positions": [
      {
        "machineId": M.id,
        "track": M.track,
        "ticker": M.ticker,
        "stock": "0x3333333333333333333333333333333333333333",
        "pending": PENDING,
        "claimed": "0",
        "frozen": false
      }
    ],
    "totals": [
      {
        "ticker": M.ticker,
        "stock": "0x3333333333333333333333333333333333333333",
        "pending": PENDING
      }
    ]
  },
  rewardTracks: {
    "tracks": [
      {
        "track": M.track,
        "ticker": M.ticker,
        "stock": "0x3333333333333333333333333333333333333333",
        "accPerWeight": "193198761",
        "totalNotified": PENDING,
        "frozen": false,
        "frozenReason": null,
        "lastNotifiedAt": 1763299990
      }
    ],
    "converter": {
      "inFallback": false,
      "paused": false,
      "lastEpochOpenedAt": 1763299980
    }
  },
  circuitLeaderboard: {
    "week": 0,
    "startsAt": 1763290000,
    "endsAt": 1763894800,
    "settled": false,
    "pot": CIRCUIT_AMOUNT,
    "completers": 1,
    "perMachine": null,
    "entries": [
      {
        "rank": 1,
        "machineId": M.id,
        "owner": "0x1111111111111111111111111111111111111111",
        "tier": M.tier,
        "relic": M.relic,
        "track": M.track,
        "flags": CIRCUIT.flags,
        "completed": CIRCUIT.completed,
        "claimable": "0",
        "claimed": false
      }
    ]
  },
  // Week 0 runs until launchAt + 1 week and nothing is claimable before a week settles, so the claim list is empty
  // while the leaderboard above shows the machine finished.
  circuitClaimable: {
    "owner": "0x1111111111111111111111111111111111111111",
    "items": [],
    "total": "0"
  },
  token: {
    "graduated": false,
    "poolPrice": null,
    "poolId": null,
    "lockedLiquidity": null,
    "volume24h": TRADE_ETH.toString(),
    "fees": {
      "hookWeth": "0",
      "rewardPot": "0",
      "lpCompounded": "0",
      "circuitPot": "0"
    },
    "holders": 1
  },
  history: {
    "address": "0x1111111111111111111111111111111111111111",
    "items": [
      {
        "kind": "curve_buy",
        "txHash": "0xabababababababababababababababababababababababababababababababab",
        "blockNumber": 1199,
        "logIndex": 4,
        "timestamp": 1763299900,
        "amount": TRADE_ETH.toString(),
        "machineId": null,
        "ticketId": null,
        "peerEid": null,
        "peerChain": null,
        "guid": null,
        "detail": TRADE_DETAIL
      }
    ],
    "nextCursor": null
  },
  params: {
    "owner": "0x2222222222222222222222222222222222222222",
    "paused": {
      "core": false,
      "buys": false,
      "hook": false,
      "converter": false
    },
    "routesSealed": true,
    "metadataFrozen": false,
    "contracts": {
      "QZCore": "0x3333333333333333333333333333333333333333"
    },
    "limits": {
      "F0_MAX_PER_WALLET": "2000000000000000000"
    }
  },
} as const satisfies { [N in RouteName]: RouteResponse<N> };

// Typed fixtures, one per route response (the compiler checks them against the read-model types).
// `npm run gen` writes them to fixtures/<route>.json; test/fixtures.test.ts fails if those files drift.
import type { RouteName, RouteResponse } from './api.ts';


export const fixtures = {
  status: {
    "chainId": 4663,
    "indexedBlock": 1200,
    "headBlock": 1203,
    "indexedAt": 1763300000,
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
    "sold": "940453707414829659318",
    "reserve": "990000000000000000",
    "price": "1179803174850230",
    "progressBps": 2645,
    "graduated": false,
    "limits": {
      "maxPerTx": "2000000000000000000",
      "maxPerWallet": "10000000000000000000"
    },
    "totals": {
      "trades": 1,
      "ethVolume": "1000000000000000000",
      "feesPaid": "10000000000000000"
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
        "ethAmount": "1000000000000000000",
        "qzAmount": "940453707414829659318",
        "fee": "10000000000000000",
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
        "machineId": 17,
        "mintedAt": 1763299700
      }
    ],
    "skipNft": false
  },
  machines: {
    "items": [
      {
        "id": 17,
        "tier": 2,
        "relic": false,
        "track": 0,
        "ticker": "NVDA",
        "owner": "0x1111111111111111111111111111111111111111",
        "eid": 30416,
        "hardwired": true
      }
    ],
    "nextCursor": null,
    "total": 4444
  },
  machine: {
    "id": 17,
    "tier": 2,
    "relic": false,
    "track": 0,
    "ticker": "NVDA",
    "owner": "0x1111111111111111111111111111111111111111",
    "eid": 30416,
    "hardwired": true,
    "weight": 15,
    "traits": [
      {
        "name": "Tier",
        "value": "II"
      },
      {
        "name": "Track",
        "value": "NVDA"
      }
    ],
    "imageUrl": null,
    "hardwiredAt": 1763299950,
    "rewards": [
      {
        "machineId": 17,
        "track": 0,
        "ticker": "NVDA",
        "stock": "0x3333333333333333333333333333333333333333",
        "pending": "1250000000000000",
        "claimed": "0",
        "frozen": false
      }
    ],
    "circuit": {
      "week": 0,
      "completed": false,
      "flags": 1
    }
  },
  rewards: {
    "owner": "0x1111111111111111111111111111111111111111",
    "positions": [
      {
        "machineId": 17,
        "track": 0,
        "ticker": "NVDA",
        "stock": "0x3333333333333333333333333333333333333333",
        "pending": "1250000000000000",
        "claimed": "0",
        "frozen": false
      }
    ],
    "totals": [
      {
        "ticker": "NVDA",
        "stock": "0x3333333333333333333333333333333333333333",
        "pending": "1250000000000000"
      }
    ]
  },
  rewardTracks: {
    "tracks": [
      {
        "track": 0,
        "ticker": "NVDA",
        "stock": "0x3333333333333333333333333333333333333333",
        "accPerWeight": "193198761",
        "totalNotified": "1250000000000000",
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
    "pot": "2500000000000000",
    "completers": 1,
    "perMachine": null,
    "entries": [
      {
        "rank": 1,
        "machineId": 17,
        "owner": "0x1111111111111111111111111111111111111111",
        "tier": 2,
        "relic": false,
        "track": 0,
        "flags": 3,
        "completed": true,
        "claimable": "0",
        "claimed": false
      }
    ]
  },
  circuitClaimable: {
    "owner": "0x1111111111111111111111111111111111111111",
    "items": [
      {
        "machineId": 17,
        "week": 0,
        "amount": "2500000000000000"
      }
    ],
    "total": "2500000000000000"
  },
  token: {
    "graduated": false,
    "poolPrice": null,
    "poolId": null,
    "lockedLiquidity": null,
    "volume24h": "1000000000000000000",
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
        "amount": "1000000000000000000",
        "machineId": null,
        "ticketId": null,
        "detail": "Bought 940.45 QZ"
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

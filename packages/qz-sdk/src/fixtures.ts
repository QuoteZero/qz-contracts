// Typed fixtures, one per route response (the compiler checks them against the read-model types).
// `npm run gen` writes them to fixtures/<route>.json; test/catalog.test.ts fails if those files drift.
import type { RouteName, RouteResponse } from './api.ts';
import { PRICE_FCFS, PRICE_GTD, PRICE_PUBLIC, TRACKS, WEIGHT_TIER_II } from './constants.ts';

// What the fixtures share is computed once, so a number that appears in two responses cannot disagree.
/**
 * The machine of the fixtures: machine 39, the first Relay on NVDA in metadata/traits.json. This file is bundled into the web app's
 * sample mode, so it cannot import the 2,222-row table; e2e/fixtures-consistency.test.ts (npm test) checks every field of M, and
 * every other machine field in this file, against that table.
 */
const M = { id: 39, tier: 2, relic: false, track: 0, ticker: TRACKS[0], weight: Number(WEIGHT_TIER_II) } as const;
const OWNER = '0x1111111111111111111111111111111111111111';
const STOCK = '0x3333333333333333333333333333333333333333';
const TX = '0xabababababababababababababababababababababababababababababababab';
const PENDING = '1250000000000000';
const MINT_TIME = 1763300100;
const LIT_TIME = 1763511000;
/** The one GTD mint of the fixtures, the machine above: its mint line, its history line and its machine page. */
const MINT = { phase: 1, price: PRICE_GTD.toString(), txHash: TX } as const;

export const fixtures = {
  status: {
    chainId: 4663,
    indexedBlock: 1203,
    headBlock: 1203,
    indexedAt: 1763520000,
    chainTime: 1763520000,
    phase: 'closed',
    minted: 1,
    finalized: true,
    hashLocked: true,
    revealed: true,
    lit: 1,
    paused: { machine: false, forge: false, converter: false },
  },
  mint: {
    chainTime: 1763520000,
    phase: 'closed',
    configured: true,
    schedule: { start: 1763290000, gtdEnd: 1763376400, fcfsEnd: 1763419600, publicEnd: 1763506000 },
    minted: 1,
    maxSupply: 2222,
    prices: { gtd: PRICE_GTD.toString(), fcfs: PRICE_FCFS.toString(), public: PRICE_PUBLIC.toString() },
    volume: PRICE_GTD.toString(),
    toConverter: ((PRICE_GTD * 25n) / 100n).toString(),
    toTreasury: ((PRICE_GTD * 75n) / 100n).toString(),
    paused: false,
    finalized: true,
    finalizedAt: 1763506100,
    hashLocked: true,
    lockedAt: 1763506200,
    revealed: true,
    revealedAt: 1763506400,
    revealOffset: '1234',
    recent: [{ machineId: M.id, minter: OWNER, ...MINT, blockNumber: 1201, timestamp: MINT_TIME }],
  },
  light: {
    lightAmount: '100000000000000000000000',
    lit: 1,
    paused: false,
    revealed: true,
    opensAt: 1763510000,
    forge: '0x4444444444444444444444444444444444444444',
    token: '0x5555555555555555555555555555555555555555',
    machines: [{ id: M.id, lit: true, litAt: LIT_TIME, canLight: false }],
  },
  machines: {
    items: [{ id: M.id, owner: OWNER, mintedAt: MINT_TIME, lit: true, litAt: LIT_TIME, tier: M.tier, relic: M.relic, track: M.track, ticker: M.ticker }],
    nextCursor: null,
    total: 1,
  },
  machine: {
    id: M.id,
    owner: OWNER,
    mintedAt: MINT_TIME,
    lit: true,
    litAt: LIT_TIME,
    tier: M.tier,
    relic: M.relic,
    track: M.track,
    ticker: M.ticker,
    weight: M.weight,
    mint: MINT,
    rewards: [{ machineId: M.id, track: M.track, ticker: M.ticker, stock: STOCK, pending: PENDING, claimed: '0', frozen: false }],
  },
  rewards: {
    owner: OWNER,
    positions: [{ machineId: M.id, track: M.track, ticker: M.ticker, stock: STOCK, pending: PENDING, claimed: '0', frozen: false }],
    totals: [{ ticker: M.ticker, stock: STOCK, pending: PENDING }],
  },
  rewardTracks: {
    tracks: [
      {
        track: M.track,
        ticker: M.ticker,
        stock: STOCK,
        accPerWeight: '38640000000000000000000000000000000',
        totalNotified: PENDING,
        frozen: false,
        frozenReason: null,
        lastNotifiedAt: 1763300000,
      },
    ],
    converter: { inFallback: false, paused: false, lastEpochOpenedAt: 1763299000 },
  },
  fees: {
    harvested: '1000000000',
    toConverter: '250000000',
    toTreasury: '750000000',
    treasuryParked: '0',
    treasuryClaimed: '750000000',
    epochsOpened: 1,
    recent: [{ caller: OWNER, total: '1000000000', toConverter: '250000000', toTreasury: '750000000', txHash: TX, blockNumber: 1202, timestamp: 1763300200 }],
  },
  history: {
    address: OWNER,
    items: [
      {
        kind: 'mint',
        txHash: TX,
        blockNumber: 1201,
        logIndex: 3,
        timestamp: MINT_TIME,
        amount: PRICE_GTD.toString(),
        machineId: M.id,
        detail: `Minted machine #${M.id}`,
      },
    ],
    nextCursor: null,
  },
  params: {
    owner: '0x2222222222222222222222222222222222222222',
    treasury: '0x2222222222222222222222222222222222222222',
    roles: {
      pauser: '0x2222222222222222222222222222222222222222',
      revealer: '0x2222222222222222222222222222222222222222',
      keeper: '0x2222222222222222222222222222222222222222',
      executor: '0x2222222222222222222222222222222222222222',
    },
    paused: { machine: false, forge: false, converter: false },
    routesSealed: true,
    metadataFrozen: false,
    contracts: { QZMachine: STOCK },
    limits: { MAX_PER_WALLET: '1' },
  },
} satisfies { [N in RouteName]: RouteResponse<N> };

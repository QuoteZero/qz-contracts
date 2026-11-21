// REST read models of the Model B chain API. JSON conventions: uint256 and USDG/QZ amounts are base-10 strings,
// addresses are lowercase 0x strings, timestamps are unix seconds, ids and block numbers are numbers.
// `apps/api/src/features/chain` serves exactly these shapes.
import type { Ticker } from './constants.ts';

export type Address = `0x${string}`;
export type Hex = `0x${string}`;
export type Wei = string;

export interface Page<T> {
  items: T[];
  nextCursor: string | null;
}

export type MintPhaseName = 'pending' | 'gtd' | 'fcfs' | 'public' | 'closed';

export interface PauseFlags {
  machine: boolean;
  forge: boolean;
  converter: boolean;
}

export interface ChainStatus {
  chainId: number;
  indexedBlock: number;
  headBlock: number;
  indexedAt: number;
  /** Unix seconds on the chain's own clock; mint windows run on it, not on the browser's. */
  chainTime: number;
  phase: MintPhaseName;
  minted: number;
  finalized: boolean;
  hashLocked: boolean;
  revealed: boolean;
  lit: number;
  paused: PauseFlags;
}

export interface MintItem {
  machineId: number;
  minter: Address;
  /** 1 GTD, 2 FCFS, 3 public. */
  phase: number;
  price: Wei;
  txHash: Hex;
  blockNumber: number;
  timestamp: number;
}

export interface MintView {
  chainTime: number;
  phase: MintPhaseName;
  configured: boolean;
  schedule: { start: number; gtdEnd: number; fcfsEnd: number; publicEnd: number } | null;
  minted: number;
  maxSupply: number;
  /** USDG, 6 decimals. */
  prices: { gtd: Wei; fcfs: Wei; public: Wei };
  volume: Wei;
  toConverter: Wei;
  toTreasury: Wei;
  paused: boolean;
  finalized: boolean;
  finalizedAt: number | null;
  hashLocked: boolean;
  lockedAt: number | null;
  revealed: boolean;
  revealedAt: number | null;
  revealOffset: Wei | null;
  recent: MintItem[];
}

export interface LightMachine {
  id: number;
  lit: boolean;
  litAt: number | null;
  /** Revealed, not yet lit, and the forge is not paused. The wallet still needs the QZ and the allowance. */
  canLight: boolean;
}

export interface LightView {
  /** QZ the forge locks per machine, 18 decimals. */
  lightAmount: Wei;
  lit: number;
  paused: boolean;
  revealed: boolean;
  opensAt: number | null;
  forge: Address;
  token: Address | null;
  machines: LightMachine[] | null;
}

export interface MachineSummary {
  id: number;
  owner: Address | null;
  mintedAt: number | null;
  lit: boolean;
  litAt: number | null;
  /** 1..4 for standard machines, 0 for relics, null until lit (the vault reveals tier and track at registration). */
  tier: number | null;
  relic: boolean;
  /** 0..9, index into TRACKS; null until lit and for relics. */
  track: number | null;
  ticker: Ticker | null;
}

export interface MachinesResponse extends Page<MachineSummary> {
  total: number;
}

export interface RewardPosition {
  machineId: number;
  track: number;
  ticker: Ticker;
  stock: Address;
  /** Stock tokens claimable now (token wei). */
  pending: Wei;
  claimed: Wei;
  frozen: boolean;
}

export interface MachineDetail extends MachineSummary {
  weight: number;
  mint: { phase: number; price: Wei; txHash: Hex } | null;
  rewards: RewardPosition[];
}

export interface RewardsResponse {
  owner: Address;
  positions: RewardPosition[];
  totals: { ticker: Ticker; stock: Address; pending: Wei }[];
}

export interface TrackInfo {
  track: number;
  ticker: Ticker;
  stock: Address;
  accPerWeight: Wei;
  totalNotified: Wei;
  frozen: boolean;
  frozenReason: Hex | null;
  lastNotifiedAt: number | null;
}

export interface TracksResponse {
  tracks: TrackInfo[];
  converter: { inFallback: boolean; paused: boolean; lastEpochOpenedAt: number | null };
}

export interface HarvestItem {
  caller: Address;
  total: Wei;
  toConverter: Wei;
  toTreasury: Wei;
  txHash: Hex;
  blockNumber: number;
  timestamp: number;
}

export interface FeesView {
  harvested: Wei;
  toConverter: Wei;
  toTreasury: Wei;
  treasuryParked: Wei;
  treasuryClaimed: Wei;
  epochsOpened: number;
  recent: HarvestItem[];
}

export type HistoryKind = 'mint' | 'light' | 'transfer' | 'reward_claim';

export interface HistoryItem {
  kind: HistoryKind;
  txHash: Hex;
  blockNumber: number;
  logIndex: number;
  timestamp: number;
  amount: Wei | null;
  machineId: number | null;
  detail: string;
}

export interface HistoryResponse extends Page<HistoryItem> {
  address: Address;
}

export interface ParamsView {
  owner: Address;
  treasury: Address;
  roles: Record<string, Address>;
  paused: PauseFlags;
  routesSealed: boolean;
  metadataFrozen: boolean;
  contracts: Record<string, Address>;
  limits: Record<string, Wei>;
}

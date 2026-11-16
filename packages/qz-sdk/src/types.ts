// Read-model types returned by the chain read API (apps/api/src/features/chain). JSON conventions:
//   uint256 / wei / QZ amounts = base-10 strings (`Wei`), addresses = lowercase-or-checksummed 0x strings,
//   timestamps = unix seconds (number), ids and block numbers = number.
import type { PhaseName, Ticker } from './constants.ts';

export type Address = `0x${string}`;
export type Hex = `0x${string}`;
/** Base-10 string of a uint256. */
export type Wei = string;

export interface Page<T> {
  items: T[];
  /** Opaque cursor for the next page; null at the end. */
  nextCursor: string | null;
}

export interface ChainStatus {
  chainId: number;
  /** Latest block indexed (reorg-safe head minus confirmations). */
  indexedBlock: number;
  headBlock: number;
  indexedAt: number;
  /** Unix seconds on the chain's own clock (timestamp of the node head at the last poll). Phases and weeks run on it; the browser's clock can differ on a forked or warped chain. */
  chainTime: number;
  phase: PhaseName;
  launchAt: number | null;
  buysPaused: boolean;
  corePaused: boolean;
  graduated: boolean;
  epoch: number;
}

export interface CurveStateView {
  phase: PhaseName;
  launchAt: number | null;
  sold: Wei;
  reserve: Wei;
  /** Wei per whole QZ. */
  price: Wei;
  /** Basis points of the 3555.2 QZ sold, 0..10000. */
  progressBps: number;
  graduated: boolean;
  /** Phase limits in force now (wei). */
  limits: { maxPerTx: Wei | null; maxPerWallet: Wei | null };
  totals: { trades: number; ethVolume: Wei; feesPaid: Wei };
}

export interface CurveTrade {
  txHash: Hex;
  blockNumber: number;
  timestamp: number;
  side: 'buy' | 'sell';
  account: Address;
  recipient: Address;
  ethAmount: Wei;
  qzAmount: Wei;
  fee: Wei;
  phase: PhaseName | null;
}

export type TicketStatus = 'pending' | 'revealed' | 'hardwired' | 'dissolved';

export interface Ticket {
  ticketId: number;
  owner: Address;
  status: TicketStatus;
  epoch: number;
  /** Seconds until the epoch seed is revealed; null once revealed. */
  revealEta: number | null;
  machineId: number | null;
  mintedAt: number;
}

export interface TicketsResponse {
  owner: Address;
  tickets: Ticket[];
  /** DN-404 skipNFT flag of the wallet (true = no tickets are minted). */
  skipNft: boolean;
}

export interface MachineSummary {
  id: number;
  /** 1..4 for standard machines, 0 for relics. */
  tier: number;
  relic: boolean;
  /** 0..9, index into TRACKS. */
  track: number;
  ticker: Ticker;
  owner: Address | null;
  /** Home chain (30416) or spoke EID while bridged (R2). */
  eid: number;
  hardwired: boolean;
}

export interface MachinesResponse extends Page<MachineSummary> {
  total: number;
}

export interface MachineDetail extends MachineSummary {
  weight: number;
  traits: { name: string; value: string }[];
  imageUrl: string | null;
  hardwiredAt: number | null;
  rewards: RewardPosition[];
  circuit: { week: number; completed: boolean; flags: number };
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

export interface RewardsResponse {
  owner: Address;
  positions: RewardPosition[];
  /** Sum of `pending` per ticker. */
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

export interface CircuitLeaderboardEntry {
  rank: number;
  machineId: number;
  owner: Address;
  /** 1..4 for standard machines, 0 for relics. */
  tier: number;
  relic: boolean;
  /** 0..9, index into TRACKS (0 for relics). */
  track: number;
  flags: number;
  completed: boolean;
  claimable: Wei;
  claimed: boolean;
}

export interface CircuitLeaderboard {
  week: number;
  startsAt: number;
  endsAt: number;
  settled: boolean;
  /** WETH pot (wei). */
  pot: Wei;
  completers: number;
  perMachine: Wei | null;
  entries: CircuitLeaderboardEntry[];
}

export interface CircuitClaimable {
  owner: Address;
  items: { machineId: number; week: number; amount: Wei }[];
  total: Wei;
}

export interface TokenStats {
  graduated: boolean;
  poolPrice: Wei | null;
  /** v4 pool id, null before graduation. */
  poolId: Hex | null;
  lockedLiquidity: Wei | null;
  volume24h: Wei;
  fees: { hookWeth: Wei; rewardPot: Wei; lpCompounded: Wei; circuitPot: Wei };
  holders: number;
}

export type HistoryKind =
  | 'curve_buy'
  | 'curve_sell'
  | 'swap'
  | 'ticket_minted'
  | 'ticket_revealed'
  | 'hardwire'
  | 'reward_claim'
  | 'circuit_hop'
  | 'circuit_claim'
  | 'transfer'
  | 'qz_sent'
  | 'qz_received'
  | 'machine_sent'
  | 'machine_received';

export interface HistoryItem {
  kind: HistoryKind;
  txHash: Hex;
  blockNumber: number;
  logIndex: number;
  timestamp: number;
  /** Primary amount in wei, when the kind has one. */
  amount: Wei | null;
  machineId: number | null;
  ticketId: number | null;
  /** Bridge kinds only: the LayerZero endpoint id of the other chain (destination of a send, source of a receive). */
  peerEid: number | null;
  /** Bridge kinds only: display name of `peerEid` (Ink, Base, ...). */
  peerChain: string | null;
  /** Bridge kinds only: LayerZero message guid; the LayerZero Scan link key. */
  guid: Hex | null;
  detail: string;
}

export interface HistoryResponse extends Page<HistoryItem> {
  address: Address;
}

export interface ParamsView {
  owner: Address;
  paused: { core: boolean; buys: boolean; hook: boolean; converter: boolean };
  routesSealed: boolean;
  metadataFrozen: boolean;
  contracts: Record<string, Address>;
  limits: Record<string, Wei>;
}

// REST route table for the chain read API. All routes are GET, JSON, prefix `/api/chain`.
import type {
  ChainStatus,
  CircuitClaimable,
  CircuitLeaderboard,
  CurveStateView,
  CurveTrade,
  HistoryResponse,
  MachineDetail,
  MachinesResponse,
  Page,
  ParamsView,
  RewardsResponse,
  TicketsResponse,
  TokenStats,
  TracksResponse,
} from './types.ts';
import type { Screen } from './events.ts';

export const API_PREFIX = '/api/chain';

export interface Route<P extends string, Q, R> {
  readonly path: P;
  readonly screens: readonly Screen[];
  readonly summary: string;
  /** Marker for types only. */
  readonly _types?: { query: Q; response: R };
}

const route = <P extends string, Q, R>(path: P, screens: readonly Screen[], summary: string): Route<P, Q, R> => ({
  path,
  screens,
  summary,
});

export const routes = {
  status: route<'/status', {}, ChainStatus>('/status', ['trade', 'admin'], 'Index head, phase, pause flags'),
  curve: route<'/curve', {}, CurveStateView>('/curve', ['trade', 'token'], 'Curve state: sold, reserve, price, progress, limits'),
  curveTrades: route<'/curve/trades', { account?: string; limit?: number; cursor?: string }, Page<CurveTrade>>(
    '/curve/trades',
    ['trade', 'token'],
    'Curve trades, newest first, optional account filter',
  ),
  tickets: route<'/tickets', { owner: string }, TicketsResponse>(
    '/tickets',
    ['machines'],
    'Pending and revealed tickets of a wallet',
  ),
  machines: route<
    '/machines',
    { owner?: string; tier?: number; track?: number; relic?: boolean; hardwired?: boolean; limit?: number; cursor?: string },
    MachinesResponse
  >('/machines', ['machines'], 'Machine gallery, filterable by owner, tier, track, relic, hardwired'),
  machine: route<'/machines/:id', {}, MachineDetail>('/machines/:id', ['machines', 'rewards', 'circuit'], 'One machine with rewards and Circuit state'),
  rewards: route<'/rewards', { owner: string }, RewardsResponse>(
    '/rewards',
    ['rewards'],
    'Claimable stock rewards per (machine, track) of a wallet',
  ),
  rewardTracks: route<'/rewards/tracks', {}, TracksResponse>('/rewards/tracks', ['rewards', 'admin'], 'Per-track accumulators and frozen state'),
  circuitLeaderboard: route<'/circuit/leaderboard', { week?: number; limit?: number; cursor?: string }, CircuitLeaderboard>(
    '/circuit/leaderboard',
    ['circuit'],
    'Weekly Circuit leaderboard and pot',
  ),
  circuitClaimable: route<'/circuit/claimable', { owner: string }, CircuitClaimable>(
    '/circuit/claimable',
    ['circuit'],
    'Unclaimed Circuit WETH per (machine, week) of a wallet',
  ),
  token: route<'/token', {}, TokenStats>('/token', ['token'], 'Post-graduation token stats'),
  history: route<'/history', { address: string; limit?: number; cursor?: string }, HistoryResponse>(
    '/history',
    ['history'],
    'Per-address activity feed',
  ),
  params: route<'/params', {}, ParamsView>('/params', ['admin'], 'Read-only parameter and pause view'),
} as const;

export type RouteName = keyof typeof routes;
type Types<N extends RouteName> = NonNullable<(typeof routes)[N]['_types']>;
export type RouteQuery<N extends RouteName> = Types<N>['query'];
export type RouteResponse<N extends RouteName> = Types<N>['response'];

/** Builds `/api/chain/...` with path params substituted and query string appended (undefined values skipped). */
export function buildUrl<N extends RouteName>(
  name: N,
  opts: { params?: Record<string, string | number>; query?: RouteQuery<N> } = {},
): string {
  let path: string = routes[name].path;
  for (const [k, v] of Object.entries(opts.params ?? {})) path = path.replace(`:${k}`, encodeURIComponent(String(v)));
  if (path.includes(':')) throw new Error(`missing path param for ${name}`);
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries((opts.query ?? {}) as Record<string, unknown>)) {
    if (v !== undefined && v !== null) qs.set(k, String(v));
  }
  const s = qs.toString();
  return `${API_PREFIX}${path}${s ? `?${s}` : ''}`;
}

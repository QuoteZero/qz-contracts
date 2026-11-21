// REST route table for the chain read API. All routes are GET, JSON, prefix `/api/chain`.
import type {
  ChainStatus,
  FeesView,
  HistoryResponse,
  LightView,
  MachineDetail,
  MachinesResponse,
  MintView,
  ParamsView,
  RewardsResponse,
  TracksResponse,
} from './types.ts';

export const API_PREFIX = '/api/chain';

export interface Route<P extends string, Q, R> {
  readonly path: P;
  readonly summary: string;
  /** Marker for types only. */
  readonly _types?: { query: Q; response: R };
}

const route = <P extends string, Q, R>(path: P, summary: string): Route<P, Q, R> => ({ path, summary });

export const routes = {
  status: route<'/status', {}, ChainStatus>('/status', 'Index head, chain clock, mint phase and pause flags'),
  mint: route<'/mint', {}, MintView>('/mint', 'Mint schedule, prices, supply, volume split and the latest mints'),
  light: route<'/light', { owner?: string }, LightView>('/light', 'Lighting state, optionally with the machines of a wallet'),
  machines: route<
    '/machines',
    { owner?: string; tier?: number; track?: number; relic?: boolean; lit?: boolean; limit?: number; cursor?: string },
    MachinesResponse
  >('/machines', 'Machine gallery, filterable by owner, tier, track, relic and lit'),
  machine: route<'/machines/:id', {}, MachineDetail>('/machines/:id', 'One machine with its mint and reward positions'),
  rewards: route<'/rewards', { owner: string }, RewardsResponse>('/rewards', 'Claimable stock rewards per (machine, track) of a wallet'),
  rewardTracks: route<'/rewards/tracks', {}, TracksResponse>('/rewards/tracks', 'Per-track accumulators, frozen state and converter status'),
  fees: route<'/fees', {}, FeesView>('/fees', 'Harvested fees, the converter and treasury split, and the latest harvests'),
  history: route<'/history', { address: string; limit?: number; cursor?: string }, HistoryResponse>('/history', 'Per-address activity feed'),
  params: route<'/params', {}, ParamsView>('/params', 'Read-only parameter, role and pause view'),
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

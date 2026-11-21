// Spec constants, generated from contracts/src/lib/QZConstants.sol. All bigint; time values in seconds.
export * from './generated/model-b/constants.ts';
export { addresses } from './generated/addresses.ts';

/** Robinhood Chain mainnet. */
export const ROBINHOOD_CHAIN_ID = 4663;
/** Track index -> ticker (order matches metadata/traits.json). */
export const TRACKS = ['NVDA', 'AAPL', 'TSLA', 'GME', 'SPY', 'PLTR', 'NFLX', 'RDDT', 'MSTR', 'SPCX'] as const;
export type Ticker = (typeof TRACKS)[number];

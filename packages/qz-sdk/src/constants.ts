// Spec constants, generated from contracts/src/lib/QZConstants.sol. All bigint; time values in seconds.
export * from './generated/constants.ts';
export { addresses } from './generated/addresses.ts';

/** LayerZero v2 endpoint ids (SPEC §5.2). */
export const EID = { robinhood: 30416, ink: 30339, base: 30184 } as const;
/** Robinhood Chain mainnet. */
export const ROBINHOOD_CHAIN_ID = 4663;
/** Track index -> ticker (order matches metadata/traits.json). */
export const TRACKS = ['NVDA', 'AAPL', 'TSLA', 'GME', 'SPY', 'PLTR', 'NFLX', 'RDDT', 'MSTR', 'SPCX'] as const;
export type Ticker = (typeof TRACKS)[number];
/** Phase enum of QZTypes.Phase. */
export const PHASES = ['Pending', 'F0', 'F1', 'F2', 'Graduated'] as const;
export type PhaseName = (typeof PHASES)[number];

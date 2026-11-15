/** Contract names of docs/SPEC.md §5.1. One interface per name in contracts/src/interfaces (`I<Name>.sol`). */
export const R1_CONTRACTS = [
  'QZCore',
  'QZDarkMirror',
  'QZEntropy',
  'QZMachine',
  'QZCurve',
  'QZHook',
  'QZRouter',
  'QZConverter',
  'QZRewardVault',
  'QZCircuit',
  'QZLiquidityLock',
] as const;

/** Release 2 (bridge). Not deployed in R1. */
export const R2_CONTRACTS = ['QZMachineAdapter', 'QZTokenAdapter', 'QZMachineONFT', 'QZTokenOFT'] as const;

export const CONTRACTS = [...R1_CONTRACTS, ...R2_CONTRACTS] as const;

export type R1ContractName = (typeof R1_CONTRACTS)[number];
export type R2ContractName = (typeof R2_CONTRACTS)[number];
export type ContractName = R1ContractName | R2ContractName;

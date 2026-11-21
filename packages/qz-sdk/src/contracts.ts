/** The six Model B contracts (SPEC Model B, B.6). One interface per name in contracts/src/interfaces (`I<Name>.sol`). */
export const CONTRACTS = ['QZMachine', 'QZForge', 'QZEntropy', 'QZFeeSplitter', 'QZConverter', 'QZRewardVault'] as const;

export type ContractName = (typeof CONTRACTS)[number];

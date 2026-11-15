import { R1_CONTRACTS, R2_CONTRACTS } from './contracts.ts';
import type { R1ContractName, R2ContractName } from './contracts.ts';

/** `deployments/<name>.json`, see deployments/README.md and schema/deployment.schema.json. */
export interface Deployment {
  /** File name without `.json`, e.g. `robinhood-mainnet`, `robinhood-testnet`, `anvil-robinhood`. */
  name: string;
  chainId: number;
  /** LayerZero v2 endpoint id of this chain, null on chains without LZ (anvil without mocks). */
  eid: number | null;
  deployedAt: string | null;
  startBlock: number;
  owner: `0x${string}`;
  treasury: `0x${string}`;
  contracts: { [K in R1ContractName]: `0x${string}` } & { [K in R2ContractName]?: `0x${string}` };
  /** Third-party addresses actually used by this deployment (PoolManager, WETH, ...). */
  external: Record<string, `0x${string}`>;
  /** v4 pool id after graduation. */
  poolId?: `0x${string}`;
  /** Spoke chains (R2): chain id -> adapter/oft addresses. */
  spokes?: Record<string, { eid: number; machine: `0x${string}`; token: `0x${string}` }>;
}

const ADDR = /^0x[0-9a-fA-F]{40}$/;

/** Hand-written validator (no runtime deps). Throws an Error listing every problem. */
export function parseDeployment(input: unknown): Deployment {
  const errors: string[] = [];
  const o = (input ?? {}) as Record<string, unknown>;
  const addr = (v: unknown, where: string) => {
    if (typeof v !== 'string' || !ADDR.test(v)) errors.push(`${where}: not an address`);
  };
  if (typeof o.name !== 'string' || !/^[a-z0-9][a-z0-9-]*$/.test(o.name)) errors.push('name: kebab-case string required');
  if (!Number.isInteger(o.chainId) || (o.chainId as number) <= 0) errors.push('chainId: positive integer required');
  if (o.eid !== null && !Number.isInteger(o.eid)) errors.push('eid: integer or null');
  if (o.deployedAt !== null && typeof o.deployedAt !== 'string') errors.push('deployedAt: ISO string or null');
  if (!Number.isInteger(o.startBlock) || (o.startBlock as number) < 0) errors.push('startBlock: non-negative integer');
  addr(o.owner, 'owner');
  addr(o.treasury, 'treasury');
  if (typeof o.contracts !== 'object' || o.contracts === null || Array.isArray(o.contracts)) {
    errors.push('contracts: object required');
  }
  const c = (typeof o.contracts === 'object' && o.contracts !== null ? o.contracts : {}) as Record<string, unknown>;
  for (const n of R1_CONTRACTS) addr(c[n], `contracts.${n}`);
  for (const n of R2_CONTRACTS) if (c[n] !== undefined) addr(c[n], `contracts.${n}`);
  for (const k of Object.keys(c)) {
    if (!(R1_CONTRACTS as readonly string[]).includes(k) && !(R2_CONTRACTS as readonly string[]).includes(k)) {
      errors.push(`contracts.${k}: unknown contract`);
    }
  }
  const ext = o.external;
  if (typeof ext !== 'object' || ext === null) errors.push('external: object required');
  else for (const [k, v] of Object.entries(ext)) addr(v, `external.${k}`);
  if (o.poolId !== undefined && (typeof o.poolId !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(o.poolId))) {
    errors.push('poolId: bytes32 hex');
  }
  if (o.spokes !== undefined) {
    const sp = o.spokes;
    if (typeof sp !== 'object' || sp === null || Array.isArray(sp)) errors.push('spokes: object keyed by chain id required');
    else {
      for (const [chain, v] of Object.entries(sp)) {
        const where = `spokes.${chain}`;
        if (!/^[1-9][0-9]*$/.test(chain)) errors.push(`${where}: key must be a positive integer chain id`);
        if (typeof v !== 'object' || v === null || Array.isArray(v)) {
          errors.push(`${where}: object { eid, machine, token } required`);
          continue;
        }
        const e = v as Record<string, unknown>;
        if (!Number.isInteger(e.eid) || (e.eid as number) <= 0) errors.push(`${where}.eid: positive integer required`);
        addr(e.machine, `${where}.machine`);
        addr(e.token, `${where}.token`);
        for (const k of Object.keys(e)) {
          if (k !== 'eid' && k !== 'machine' && k !== 'token') errors.push(`${where}.${k}: unknown field`);
        }
      }
    }
  }
  if (errors.length > 0) throw new Error(`invalid deployment:\n - ${errors.join('\n - ')}`);
  return o as unknown as Deployment;
}

import { CONTRACTS } from './contracts.ts';
import type { ContractName } from './contracts.ts';

type Hex = `0x${string}`;

/** `deployments/<name>.json` as the testnet deploy tooling writes it; see schema/deployment.schema.json. */
export interface Deployment {
  /** File name without `.json`, e.g. `robinhood`, `robinhood-testnet`, `anvil-robinhood`. */
  name: string;
  chainId: number;
  /** LayerZero v2 endpoint id of the chain, as written by the deploy script. */
  eid: number;
  deployedAt: string;
  /** Block of the first deployment transaction; the indexer starts here. */
  startBlock: number;
  explorer: string;
  owner: Hex;
  treasury: Hex;
  roles: { pauser: Hex; revealer: Hex; keeper: Hex; executor: Hex };
  schedule: {
    mintWindows: { gtd: number; fcfs: number; publicMax: number };
    mintStart: number;
    lightingOpensAt: number;
    onionLength: number;
  };
  contracts: Record<ContractName, Hex>;
  /** Third-party addresses the deployment uses (PoolManager, WETH, USDG, v3 factory and router). */
  external: Record<string, Hex>;
  /** The Pons launchpad objects of the QZ token. */
  pons: { factory: Hex; escrow: Hex; hook: Hex; token: Hex };
  /** One flag per verified contract. */
  verified?: Record<string, boolean>;
  /** Stand-ins deployed on the testnet only. */
  testnetMocks?: Record<string, unknown>;
}

const ADDR = /^0x[0-9a-fA-F]{40}$/;
const NAME = /^[a-z0-9][a-z0-9-]*$/;

/** Hand-written validator (no runtime deps). Throws an Error listing every problem. */
export function parseDeployment(input: unknown): Deployment {
  const errors: string[] = [];
  const o = (input ?? {}) as Record<string, unknown>;
  const obj = (v: unknown): Record<string, unknown> | null => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null);
  const addr = (v: unknown, where: string) => {
    if (typeof v !== 'string' || !ADDR.test(v)) errors.push(`${where}: not an address`);
  };
  const int = (v: unknown, where: string, min: number) => {
    if (!Number.isInteger(v) || (v as number) < min) errors.push(`${where}: integer >= ${min} required`);
  };
  if (typeof o.name !== 'string' || !NAME.test(o.name)) errors.push('name: kebab-case string required');
  int(o.chainId, 'chainId', 1);
  int(o.eid, 'eid', 1);
  if (typeof o.deployedAt !== 'string') errors.push('deployedAt: ISO string required');
  int(o.startBlock, 'startBlock', 0);
  if (typeof o.explorer !== 'string') errors.push('explorer: string required (empty when there is none)');
  addr(o.owner, 'owner');
  addr(o.treasury, 'treasury');

  const roles = obj(o.roles);
  if (!roles) errors.push('roles: object required');
  for (const r of ['pauser', 'revealer', 'keeper', 'executor']) addr(roles?.[r], `roles.${r}`);

  const schedule = obj(o.schedule);
  if (!schedule) errors.push('schedule: object required');
  else {
    int(schedule.mintStart, 'schedule.mintStart', 0);
    int(schedule.lightingOpensAt, 'schedule.lightingOpensAt', 0);
    int(schedule.onionLength, 'schedule.onionLength', 1);
    const w = obj(schedule.mintWindows);
    if (!w) errors.push('schedule.mintWindows: object required');
    for (const k of ['gtd', 'fcfs', 'publicMax']) int(w?.[k], `schedule.mintWindows.${k}`, 1);
  }

  const contracts = obj(o.contracts);
  if (!contracts) errors.push('contracts: object required');
  const seen = new Map<string, string>();
  for (const n of CONTRACTS) {
    addr(contracts?.[n], `contracts.${n}`);
    const a = contracts?.[n];
    if (typeof a === 'string' && ADDR.test(a)) {
      const other = seen.get(a.toLowerCase());
      if (other) errors.push(`contracts.${n}: shares an address with ${other}`);
      seen.set(a.toLowerCase(), n);
    }
  }
  for (const k of Object.keys(contracts ?? {})) {
    if (!(CONTRACTS as readonly string[]).includes(k)) errors.push(`contracts.${k}: unknown contract`);
  }

  const ext = obj(o.external);
  if (!ext) errors.push('external: object required');
  else for (const [k, v] of Object.entries(ext)) addr(v, `external.${k}`);

  const pons = obj(o.pons);
  if (!pons) errors.push('pons: object required');
  for (const k of ['factory', 'escrow', 'hook', 'token']) addr(pons?.[k], `pons.${k}`);

  const verified = o.verified;
  if (verified !== undefined) {
    const v = obj(verified);
    if (!v) errors.push('verified: object of booleans required');
    else for (const [k, flag] of Object.entries(v)) if (typeof flag !== 'boolean') errors.push(`verified.${k}: boolean required`);
  }
  if (o.testnetMocks !== undefined && !obj(o.testnetMocks)) errors.push('testnetMocks: object required');

  if (errors.length > 0) throw new Error(`invalid deployment:\n - ${errors.join('\n - ')}`);
  return o as unknown as Deployment;
}

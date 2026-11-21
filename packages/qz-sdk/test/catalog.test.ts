import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { CONTRACTS, TRACKS, buildUrl, modelBAbis, routes } from '../src/index.ts';
import { fixtures } from '../src/fixtures.ts';
import { applyBlocks } from '../scripts/gen-docs.ts';
import { parseDeployment } from '../src/deployment.ts';
import { loadDeployment } from '../src/node.ts';
import * as K from '../src/constants.ts';
import { parseIntegerConstants } from '../scripts/sol-eval.ts';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..', '..', '..');
const pkg = resolve(here, '..');

test('every route has a fixture file identical to the typed fixture', () => {
  assert.deepEqual(Object.keys(fixtures).sort(), Object.keys(routes).sort());
  for (const [name, value] of Object.entries(fixtures)) {
    const onDisk = JSON.parse(readFileSync(join(pkg, 'fixtures', `${name}.json`), 'utf8'));
    assert.deepEqual(onDisk, JSON.parse(JSON.stringify(value)), `${name}.json is stale (run npm run gen)`);
  }
  assert.deepEqual(readdirSync(join(pkg, 'fixtures')).length, Object.keys(routes).length);
});

test('buildUrl', () => {
  assert.equal(buildUrl('machine', { params: { id: 17 } }), '/api/chain/machines/17');
  assert.equal(buildUrl('rewards', { query: { owner: '0xabc' } }), '/api/chain/rewards?owner=0xabc');
  assert.equal(buildUrl('machines', { query: { lit: true, limit: 20 } }), '/api/chain/machines?lit=true&limit=20');
  assert.equal(buildUrl('rewardTracks'), '/api/chain/rewards/tracks');
  assert.throws(() => buildUrl('machine'));
});

test('docs/CONTRACT.md generated blocks are current', () => {
  const doc = readFileSync(join(repo, 'docs', 'CONTRACT.md'), 'utf8');
  assert.equal(applyBlocks(doc, repo), doc, 'run npm run gen');
});

test('generated constants equal the Solidity source', () => {
  const sol = readFileSync(join(repo, 'contracts/src/lib/QZConstants.sol'), 'utf8');
  const parsed = parseIntegerConstants(sol, () => 0n);
  assert.ok(parsed.length > 0);
  for (const c of parsed) assert.equal((K as Record<string, unknown>)[c.name], c.value, c.name);
  assert.equal(K.TOTAL_MACHINES, 2222n);
  assert.equal(BigInt(TRACKS.length), K.TRACK_COUNT);
});

test('the contract list is the six Model B names and each has an ABI', () => {
  assert.deepEqual([...CONTRACTS], ['QZMachine', 'QZForge', 'QZEntropy', 'QZFeeSplitter', 'QZConverter', 'QZRewardVault']);
  assert.deepEqual(Object.keys(modelBAbis), [...CONTRACTS]);
});

const addr = (n: number) => `0x${n.toString(16).padStart(40, '0')}`;
const sample = () => ({
  name: 'anvil-robinhood',
  chainId: 4663,
  eid: 30416,
  deployedAt: '2026-11-21T00:00:00Z',
  startBlock: 1,
  explorer: '',
  owner: addr(1),
  treasury: addr(2),
  roles: { pauser: addr(3), revealer: addr(4), keeper: addr(5), executor: addr(6) },
  schedule: { mintWindows: { gtd: 86400, fcfs: 43200, publicMax: 86400 }, mintStart: 1, lightingOpensAt: 2, onionLength: 64 },
  contracts: Object.fromEntries(CONTRACTS.map((n, i) => [n, addr(10 + i)])),
  external: { POOL_MANAGER: addr(99) },
  pons: { factory: addr(30), escrow: addr(31), hook: addr(32), token: addr(33) },
});

test('deployment validator', () => {
  assert.equal(parseDeployment(sample()).chainId, 4663);
  const bad = sample();
  delete (bad.contracts as Record<string, unknown>).QZForge;
  assert.throws(() => parseDeployment(bad), /contracts.QZForge/);
  assert.throws(() => parseDeployment({ ...sample(), owner: '0x1' }), /owner/);
  assert.throws(() => parseDeployment({ ...sample(), contracts: 42 }), /contracts: object/);
  assert.throws(() => parseDeployment({ ...sample(), contracts: { ...sample().contracts, QZUnknown: addr(77) } }), /contracts.QZUnknown: unknown contract/);
  assert.throws(() => parseDeployment({ ...sample(), contracts: { ...sample().contracts, QZForge: addr(10) } }), /shares an address/);
  assert.throws(() => parseDeployment({ ...sample(), roles: undefined }), /roles: object/);
  assert.throws(() => parseDeployment({ ...sample(), schedule: { ...sample().schedule, mintWindows: { gtd: 0, fcfs: 1, publicMax: 1 } } }), /mintWindows.gtd/);
  assert.throws(() => parseDeployment({ ...sample(), pons: { ...sample().pons, token: 'nope' } }), /pons.token/);
  assert.throws(() => parseDeployment({ ...sample(), verified: { QZMachine: 'yes' } }), /verified.QZMachine/);
});

test('deployment schema lists the same contracts as the SDK', () => {
  const schema = JSON.parse(readFileSync(join(pkg, 'schema', 'deployment.schema.json'), 'utf8'));
  assert.deepEqual(schema.properties.contracts.required, [...CONTRACTS]);
  assert.deepEqual(Object.keys(schema.properties.contracts.properties), [...CONTRACTS]);
});

test('the deployment files of the repo satisfy the validator', () => {
  const dir = join(repo, 'deployments');
  const files = readdirSync(dir).filter((f) => /^[a-z0-9][a-z0-9-]*\.json$/.test(f) && !/\.(proof|scenario-state)\.json$/.test(f));
  assert.ok(files.length > 0);
  for (const f of files) assert.equal(loadDeployment(f.replace(/\.json$/, ''), dir).name, f.replace(/\.json$/, ''));
});

test('loadDeployment reads and validates a file', () => {
  const dir = mkdtempSync(join(tmpdir(), 'qzdep-'));
  try {
    writeFileSync(join(dir, 'anvil-robinhood.json'), JSON.stringify(sample()));
    assert.equal(loadDeployment('anvil-robinhood', dir).name, 'anvil-robinhood');
    assert.throws(() => loadDeployment('../x', dir));
    writeFileSync(join(dir, 'other.json'), JSON.stringify(sample()));
    assert.throws(() => loadDeployment('other', dir), /declares name/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

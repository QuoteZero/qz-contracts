import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { toEventSelector } from 'viem';
import type { AbiEvent } from 'viem';
import {
  CONTRACTS,
  EID,
  R1_CONTRACTS,
  SCREENS,
  TRACKS,
  abis,
  buildUrl,
  eventCatalog,
  eventMeta,
  routes,
} from '../src/index.ts';
import { fixtures } from '../src/fixtures.ts';
import { applyBlocks } from '../scripts/gen-docs.ts';
import { parseDeployment } from '../src/deployment.ts';
import { loadDeployment } from '../src/node.ts';
import * as K from '../src/constants.ts';
import { parseIntegerConstants } from '../scripts/sol-eval.ts';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..', '..', '..');
const pkg = resolve(here, '..');

test('catalog covers every ABI event exactly once with the right topic0', () => {
  const fromAbi = new Set<string>();
  for (const c of CONTRACTS) {
    for (const item of abis[c]) {
      if (item.type !== 'event') continue;
      const key = `${c}.${item.name}`;
      fromAbi.add(key);
      const entry = eventCatalog.find((e) => e.key === key);
      assert.ok(entry, `${key} missing in catalog`);
      assert.equal(entry.topic0, toEventSelector(item as AbiEvent));
    }
  }
  assert.deepEqual([...fromAbi].sort(), eventCatalog.map((e) => e.key).sort());
  assert.deepEqual(Object.keys(eventMeta).sort(), [...fromAbi].sort());
});

test('catalog entries are complete', () => {
  for (const e of eventCatalog) {
    assert.ok(e.when.length > 10, e.key);
    for (const s of e.screens) assert.ok((SCREENS as readonly string[]).includes(s));
    assert.equal(e.r2 === true, !(R1_CONTRACTS as readonly string[]).includes(e.contract), e.key);
  }
});

test('every route has a fixture file identical to the typed fixture, and screens are covered', () => {
  assert.deepEqual(Object.keys(fixtures).sort(), Object.keys(routes).sort());
  for (const [name, value] of Object.entries(fixtures)) {
    const onDisk = JSON.parse(readFileSync(join(pkg, 'fixtures', `${name}.json`), 'utf8'));
    assert.deepEqual(onDisk, JSON.parse(JSON.stringify(value)), `${name}.json is stale (run npm run gen)`);
  }
  assert.deepEqual(readdirSync(join(pkg, 'fixtures')).length, Object.keys(routes).length);
  const covered = new Set(Object.values(routes).flatMap((r) => r.screens));
  for (const s of ['trade', 'machines', 'rewards', 'circuit', 'token', 'history', 'admin'] as const) {
    assert.ok(covered.has(s), `no route serves screen ${s}`);
  }
});

test('buildUrl', () => {
  assert.equal(buildUrl('machine', { params: { id: 17 } }), '/api/chain/machines/17');
  assert.equal(buildUrl('tickets', { query: { owner: '0xabc' } }), '/api/chain/tickets?owner=0xabc');
  assert.equal(buildUrl('curveTrades', { query: { limit: 20 } }), '/api/chain/curve/trades?limit=20');
  assert.throws(() => buildUrl('machine'));
});

test('docs/CONTRACT.md generated blocks are current', () => {
  const doc = readFileSync(join(repo, 'docs', 'CONTRACT.md'), 'utf8');
  assert.equal(applyBlocks(doc, repo), doc, 'run npm run gen');
});

test('generated constants equal the Solidity source', () => {
  const sol = readFileSync(join(repo, 'contracts/src/lib/QZConstants.sol'), 'utf8');
  const parsed = parseIntegerConstants(sol, () => 0n).filter((c) => c.name !== 'HOOK_FLAGS');
  for (const c of parsed) assert.equal((K as Record<string, unknown>)[c.name], c.value, c.name);
  assert.equal(K.TOTAL_SUPPLY, 4444n * 10n ** 18n);
  assert.equal(K.EID_ROBINHOOD, BigInt(EID.robinhood));
  assert.equal(K.EID_INK, BigInt(EID.ink));
  assert.equal(K.EID_BASE, BigInt(EID.base));
  assert.equal(BigInt(TRACKS.length), K.TRACK_COUNT);
  assert.equal(K.HOOK_FLAGS, (1n << 13n) | (1n << 11n) | (1n << 7n) | (1n << 6n) | (1n << 2n));
});

const addr = (n: number) => `0x${n.toString(16).padStart(40, '0')}`;
const sample = () => ({
  name: 'anvil-robinhood',
  chainId: 4663,
  eid: 30416,
  deployedAt: null,
  startBlock: 1,
  owner: addr(1),
  treasury: addr(2),
  contracts: Object.fromEntries(R1_CONTRACTS.map((n, i) => [n, addr(10 + i)])),
  external: { POOL_MANAGER: addr(99) },
});

test('deployment validator', () => {
  assert.equal(parseDeployment(sample()).chainId, 4663);
  const bad = sample();
  delete (bad.contracts as Record<string, unknown>).QZCurve;
  assert.throws(() => parseDeployment(bad), /contracts.QZCurve/);
  assert.throws(() => parseDeployment({ ...sample(), owner: '0x1' }), /owner/);
});

test('deployment validator checks optional spokes', () => {
  const spoke = { eid: 30339, machine: addr(50), token: addr(51) };
  assert.deepEqual(parseDeployment({ ...sample(), spokes: { '57073': spoke } }).spokes, { '57073': spoke });
  assert.throws(() => parseDeployment({ ...sample(), spokes: 42 }), /spokes: object/);
  assert.throws(() => parseDeployment({ ...sample(), spokes: null }), /spokes: object/);
  assert.throws(() => parseDeployment({ ...sample(), spokes: [] }), /spokes: object/);
  assert.throws(() => parseDeployment({ ...sample(), spokes: { '57073': 7 } }), /spokes.57073: object/);
  assert.throws(() => parseDeployment({ ...sample(), spokes: { '57073': { ...spoke, eid: 'x' } } }), /eid/);
  assert.throws(() => parseDeployment({ ...sample(), spokes: { '57073': { ...spoke, eid: 1.5 } } }), /eid/);
  assert.throws(() => parseDeployment({ ...sample(), spokes: { '57073': { ...spoke, machine: '0x12' } } }), /machine/);
  assert.throws(() => parseDeployment({ ...sample(), spokes: { '57073': { ...spoke, token: undefined } } }), /token/);
  assert.throws(() => parseDeployment({ ...sample(), spokes: { abc: spoke } }), /chain id/);
  assert.throws(() => parseDeployment({ ...sample(), spokes: { '57073': { ...spoke, extra: 1 } } }), /unknown field/);
  assert.throws(() => parseDeployment({ ...sample(), contracts: 42 }), /contracts: object/);
});

test('deployment schema lists the same contracts as the SDK', () => {
  const schema = JSON.parse(readFileSync(join(pkg, 'schema', 'deployment.schema.json'), 'utf8'));
  assert.deepEqual(schema.properties.contracts.required, [...R1_CONTRACTS]);
  assert.deepEqual(Object.keys(schema.properties.contracts.properties), [...CONTRACTS]);
});

test('loadDeployment reads and validates a file', async () => {
  const { mkdtempSync, writeFileSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const dir = mkdtempSync(join(tmpdir(), 'qzdep-'));
  writeFileSync(join(dir, 'anvil-robinhood.json'), JSON.stringify(sample()));
  assert.equal(loadDeployment('anvil-robinhood', dir).name, 'anvil-robinhood');
  assert.throws(() => loadDeployment('../x', dir));
});

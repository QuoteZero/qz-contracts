// Model B surface (B0): ABIs, event topics and constants agree with the Solidity interfaces and QZConstants.sol.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { toEventSelector } from 'viem';
import type { AbiEvent } from 'viem';

import * as K from '../src/constants.ts';
import { modelBAbis } from '../src/generated/model-b/abis.ts';
import { modelBEventTopics } from '../src/generated/model-b/topics.ts';

const MODEL_B_CONTRACTS = ['QZMachine', 'QZForge', 'QZEntropy', 'QZFeeSplitter', 'QZConverter', 'QZRewardVault'] as const;
const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..', '..', '..');

const names = (contract: keyof typeof modelBAbis, type: 'function' | 'event' | 'error') =>
  (modelBAbis[contract] as readonly { type: string; name?: string }[])
    .filter((i) => i.type === type)
    .map((i) => i.name);

test('every Model B contract has an ABI and an interface file', () => {
  assert.deepEqual(Object.keys(modelBAbis).sort(), [...MODEL_B_CONTRACTS].sort());
  for (const c of MODEL_B_CONTRACTS) {
    readFileSync(join(repo, 'contracts/src/interfaces', `I${c}.sol`), 'utf8');
  }
});

test('event topics match the ABI events', () => {
  const fromAbi: string[] = [];
  for (const c of MODEL_B_CONTRACTS) {
    for (const item of modelBAbis[c]) {
      if (item.type !== 'event') continue;
      const key = `${c}.${item.name}`;
      fromAbi.push(key);
      assert.equal(modelBEventTopics[key as keyof typeof modelBEventTopics].topic0, toEventSelector(item as AbiEvent));
    }
  }
  assert.deepEqual(fromAbi.sort(), Object.keys(modelBEventTopics).sort());
});

test('the mechanism is on the surface the website and the deploy read', () => {
  assert.ok(names('QZMachine', 'function').includes('mint'));
  assert.ok(names('QZMachine', 'function').includes('reveal'));
  assert.ok(names('QZMachine', 'event').includes('Minted'));
  assert.ok(names('QZMachine', 'event').includes('Revealed'));
  for (const fn of [
    'lockHash',
    'rearmReveal',
    'hashLocked',
    'finalizeBlock',
    'lockedHash',
    'lockedAt',
    'gtdWindow',
    'fcfsWindow',
    'publicWindowMax',
  ]) {
    assert.ok(names('QZMachine', 'function').includes(fn), fn);
  }
  for (const ev of ['HashLocked', 'RevealRearmed', 'MintWindowExtended']) {
    assert.ok(names('QZMachine', 'event').includes(ev), ev);
  }
  for (const err of ['RevealTooEarly', 'RevealWindowMissed', 'RevealWindowOpen', 'HashAlreadyLocked', 'HashNotLocked', 'ZeroBlockHash']) {
    assert.ok(names('QZMachine', 'error').includes(err), err);
  }
  assert.ok(names('QZForge', 'function').includes('light'));
  assert.ok(names('QZForge', 'function').includes('litCount'));
  assert.ok(names('QZForge', 'event').includes('Lit'));
  assert.ok(names('QZFeeSplitter', 'function').includes('harvest'));
  for (const fn of ['pendingTreasury', 'claimPendingTreasury']) {
    assert.ok(names('QZFeeSplitter', 'function').includes(fn), fn);
  }
  for (const ev of ['TreasuryShareParked', 'TreasuryShareClaimed']) {
    assert.ok(names('QZFeeSplitter', 'event').includes(ev), ev);
  }
  for (const err of ['NotTreasury', 'NothingPending']) {
    assert.ok(names('QZFeeSplitter', 'error').includes(err), err);
  }
  assert.ok(names('QZConverter', 'function').includes('convert'));
  assert.ok(names('QZRewardVault', 'function').includes('notify'));
  assert.ok(names('QZRewardVault', 'function').includes('claim'));
});

test('Model B constants carry the SPEC values', () => {
  assert.equal(K.TOTAL_MACHINES, 2222n);
  assert.equal(K.LIGHT_AMOUNT, 100_000n * 10n ** 18n);
  assert.equal(K.PRICE_GTD, 3_000_000n);
  assert.equal(K.PRICE_FCFS, 4_000_000n);
  assert.equal(K.PRICE_PUBLIC, 5_000_000n);
  assert.equal(K.MINT_REWARD_BPS + K.MINT_TREASURY_BPS, K.BPS);
  assert.equal(K.REWARD_PART, 20n);
  assert.equal(K.TREASURY_PART, 7n);
});

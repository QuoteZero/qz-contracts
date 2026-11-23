#!/usr/bin/env node
// Closing Bell deployment record and source verification (Robinhood testnet, chain 46630 only).
//
//   node contracts/script/dapps/deploy-record.mjs write    deployments/robinhood-testnet.closing-bell.json from the broadcast
//   node contracts/script/dapps/deploy-record.mjs verify   verify QZBoardSource and QZCloseBell on Blockscout, write the flags
//   node contracts/script/dapps/deploy-record.mjs verify --print-only
//
// `write` reads contracts/broadcast/DeployCloseBell.s.sol/46630/run-latest.json (written by
// `forge script script/dapps/DeployCloseBell.s.sol:DeployCloseBell --broadcast`) and the receipts in it. It keeps an
// existing `verified` block. `verify` is idempotent: run it again until nothing is pending (Blockscout's queue is
// slow, forge's --watch times out on submissions that are accepted minutes later).
//
// Environment: QZ_EXPLORER_API (default http://127.0.0.1:8547/api/), QZ_DEPLOYMENTS_DIR, QZ_BROADCAST_FILE.

import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');
const contractsDir = path.join(repo, 'contracts');
const DIR = process.env.QZ_DEPLOYMENTS_DIR || path.join(repo, 'deployments');
const OUT = path.join(DIR, 'robinhood-testnet.closing-bell.json');
const API = process.env.QZ_EXPLORER_API || 'http://127.0.0.1:8547/api/';
const CHAIN = 46630;
const BROADCAST =
  process.env.QZ_BROADCAST_FILE || path.join(contractsDir, 'broadcast', 'DeployCloseBell.s.sol', String(CHAIN), 'run-latest.json');
const NAMES = ['QZBoardSource', 'QZCloseBell'];

const bc = JSON.parse(fs.readFileSync(BROADCAST, 'utf8'));
if (bc.chain !== CHAIN) throw new Error(`broadcast is for chain ${bc.chain}, not ${CHAIN}`);
const creates = bc.transactions.filter((t) => t.transactionType === 'CREATE' && NAMES.includes(t.contractName));
if (creates.length !== 2) throw new Error('broadcast must hold one QZBoardSource and one QZCloseBell creation');
const byName = Object.fromEntries(creates.map((t) => [t.contractName, t]));

const prev = fs.existsSync(OUT) ? JSON.parse(fs.readFileSync(OUT, 'utf8')) : {};

const checksum = (a) => execFileSync('cast', ['to-check-sum-address', a], {encoding: 'utf8'}).trim();

function write() {
  const receipt = (t) => bc.receipts.find((r) => r.transactionHash.toLowerCase() === t.hash.toLowerCase());
  const tx = {};
  for (const n of NAMES) {
    const r = receipt(byName[n]);
    if (!r || BigInt(r.status) !== 1n) throw new Error(`${n} creation has no successful receipt in the broadcast`);
    tx[n] = {hash: byName[n].hash, blockNumber: Number(BigInt(r.blockNumber)), gasUsed: Number(BigInt(r.gasUsed))};
  }
  const bell = byName.QZCloseBell.arguments;
  const profile = bell[8].replace(/[()\s]/g, '').split(',').map(Number);
  const deployer = byName.QZBoardSource.arguments[0];
  const dep = {
    name: 'robinhood-testnet-closing-bell',
    chainId: CHAIN,
    deployedAt: new Date(bc.timestamp).toISOString(),
    startBlock: tx.QZBoardSource.blockNumber,
    explorer: 'https://explorer.testnet.chain.robinhood.com',
    deployer,
    roles: {calendar: bell[5], treasury: bell[6], poster: byName.QZBoardSource.arguments[1], boardOwner: deployer, sponsor: bell[7]},
    profile: {voidAfter: profile[0], claimDelay: profile[1], minLead: profile[2], snapshotDelay: profile[3]},
    board: {maxAge: Number(byName.QZBoardSource.arguments[2]), supportedMask: Number(byName.QZBoardSource.arguments[3])},
    contracts: {QZBoardSource: checksum(byName.QZBoardSource.contractAddress), QZCloseBell: checksum(byName.QZCloseBell.contractAddress)},
    dependencies: {QZMachine: bell[0], QZForge: bell[1], qz: bell[2], usdg: bell[3]},
    transactions: tx,
    verified: prev.verified || {},
  };
  fs.mkdirSync(DIR, {recursive: true});
  fs.writeFileSync(OUT, JSON.stringify(dep, null, 2) + '\n');
  console.log(`wrote ${path.relative(repo, OUT)}`);
}

function artifact(name) {
  const a = JSON.parse(fs.readFileSync(path.join(contractsDir, 'out', `${name}.sol`, `${name}.json`), 'utf8'));
  const target = Object.entries(a.metadata.settings.compilationTarget)[0];
  return {source: `${target[0]}:${target[1]}`, bytecode: a.bytecode.object.toLowerCase()};
}

function verify() {
  const PRINT = process.argv.includes('--print-only');
  const dep = JSON.parse(fs.readFileSync(OUT, 'utf8'));
  const verified = {...dep.verified};
  for (const name of NAMES) {
    const t = byName[name];
    const a = artifact(name);
    const init = (t.transaction.input ?? t.transaction.data).toLowerCase();
    if (!init.startsWith(a.bytecode)) throw new Error(`${name}: creation code differs from the compiled artifact (rebuild first)`);
    const args = init.slice(a.bytecode.length);
    const cmd = [
      'verify-contract', t.contractAddress, a.source, '--chain', String(CHAIN), '--verifier', 'blockscout',
      '--verifier-url', API, '--compiler-version', '0.8.26', '--watch', ...(args ? ['--constructor-args', '0x' + args] : []),
    ];
    if (PRINT) {
      console.log(`(cd contracts && forge ${cmd.join(' ')})`);
      continue;
    }
    if (verified[name] === true) continue;
    try {
      execFileSync('forge', cmd, {cwd: contractsDir, env: process.env, stdio: ['ignore', 'pipe', 'pipe']});
      verified[name] = true;
      console.log(`verified ${name} ${t.contractAddress}`);
    } catch (e) {
      verified[name] = false;
      console.error(`NOT verified ${name} ${t.contractAddress}: ${String(e.stderr || e.message).trim().split('\n').slice(-2).join(' | ')}`);
    }
  }
  if (PRINT) return;
  dep.verified = verified;
  fs.writeFileSync(OUT, JSON.stringify(dep, null, 2) + '\n');
  const bad = NAMES.filter((n) => !verified[n]);
  console.log(`verified flags written; not verified: ${bad.length ? bad.join(', ') : 'none'}`);
  process.exit(bad.length ? 1 : 0);
}

const cmd = process.argv[2];
if (cmd === 'write') write();
else if (cmd === 'verify') verify();
else {
  console.error('usage: deploy-record.mjs write|verify [--print-only]');
  process.exit(2);
}

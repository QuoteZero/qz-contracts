#!/usr/bin/env node
// Closing Bell (QZCloseBell) end-to-end scenario on the Robinhood testnet (chain 46630 only), real transactions on the
// real clock. Modelled on contracts/script/model-b/scenario.mjs: every transaction is signed first, written to the state
// file, then published, so a run cut off at any instant resumes the same transaction instead of signing a new one.
//
//   node contracts/script/dapps/scenario.mjs run       do every step that is due, sleeping until the next one; resumable
//   node contracts/script/dapps/scenario.mjs status    steps recorded so far, the next failure if any
//   node contracts/script/dapps/scenario.mjs assert    re-read the final assertions from the chain (writes nothing)
//
// Reads  deployments/robinhood-testnet.closing-bell.json (DeployCloseBell + deploy-record.mjs) and
//        deployments/robinhood-testnet.json (the Model B set the Bell reads).
// Writes deployments/robinhood-testnet.closing-bell.proof.json   {generatedAt, steps:[...]}
//        deployments/robinhood-testnet.closing-bell.scenario-state.json   (calendar anchor, balances read before a step,
//        the transactions written ahead and the last failure)
// A step is one of: a transaction (`txHash`, `blockNumber`, `gasUsed`), an expected revert read with eth_call
// (`kind: "eth_call-revert"`, the revert `selector` and `data`), or an on-chain assertion (`kind: "assert"`).
//
// Keys come from the environment of this process only (DEPLOYER_PRIVATE_KEY, USER_A_PRIVATE_KEY, USER_B_PRIVATE_KEY,
// loaded with `secret env-file`) and reach `cast` through throwaway keystores that are removed on exit. The public
// wallet's key is derived from the deployer key exactly as in the Model B scenario.
//
// Actors. deployer = calendar, treasury, board poster and owner, third-party snapshotter and settler. user-a and
// user-b are the Model B wallets. public is the wallet that owns machine #3. Machines: #1 NVDA-slot track 9 (owned by
// user-b, moved to user-a mid-run), #2 track 4 (user-b), #3 track 5 (public). Tracks 9, 4 and 5 are the testnet
// machines' own tracks, so each machine calls its own ticker.
//
// Calendar (S = first opensAt; session k opens at S + 300 (k-1), cutoff +210 s, close +270 s):
//   close1 = S+270, close2 = S+570, close3 = S+870, close4 = S+1170, claimOpensAt = close4 + 1200 = S+2370.

import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import crypto from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');
const DIR = process.env.QZ_DEPLOYMENTS_DIR || path.join(repo, 'deployments');
const RPC = process.env.QZ_RPC_URL || 'http://127.0.0.1:8546';
const CHAIN_ID = 46630;
const BELL_FILE = path.join(DIR, 'robinhood-testnet.closing-bell.json');
const MODELB_FILE = path.join(DIR, 'robinhood-testnet.json');
const PROOF_FILE = path.join(DIR, 'robinhood-testnet.closing-bell.proof.json');
const STATE_FILE = path.join(DIR, 'robinhood-testnet.closing-bell.scenario-state.json');
const LOCK_FILE = path.join(DIR, 'robinhood-testnet.closing-bell.scenario.lock');
const TX_WAIT_MS = Number(process.env.QZ_TX_WAIT_SECONDS || 180) * 1000;
const CMD = process.argv[2] || 'run';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const E18 = 10n ** 18n;
const DEAD = '0x000000000000000000000000000000000000dEaD';
const ANTE = 1000n * E18;
const PURSE = 500_000_000n; // 500 mock USDG (6 decimals)
const UP = 1;
const DOWN = 2;
const STATUS = {None: 0, Up: 1, Down: 2, Closed: 3, Flat: 4, Expired: 5};
const T_M1 = 9;
const T_M2 = 4;
const T_M3 = 5;
const T_NOTCALLABLE = 6; // NFLX: outside the board mask 0x33F
const px = (n) => String(BigInt(n) * 10n ** 8n);

// ───────────── cast plumbing ─────────────

const KEY_ENV = {deployer: 'DEPLOYER_PRIVATE_KEY', 'user-a': 'USER_A_PRIVATE_KEY', 'user-b': 'USER_B_PRIVATE_KEY'};

function cast(args, {input} = {}) {
  const env = {...process.env};
  for (const k of [...Object.values(KEY_ENV), 'ETH_PRIVATE_KEY', 'FOUNDRY_PROFILE']) delete env[k];
  try {
    return execFileSync('cast', args, {env, input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe']}).trim();
  } catch (e) {
    const msg = String((e.stderr && String(e.stderr).trim()) || (e.stdout && String(e.stdout).trim()) || e.message)
      .split('\n').filter((l) => !/^Warning:/.test(l)).slice(0, 8).join(' | ');
    const err = new Error(`cast ${args[0]} ${args.slice(1, 3).join(' ')}: ${msg}`);
    err.revert = msg;
    throw err;
  }
}

const keccak = (hex) => cast(['keccak', hex]);

function read(to, sig, args = []) {
  const out = JSON.parse(cast(['call', '--rpc-url', RPC, '--json', to, sig, ...args.map(String)]));
  return out.length === 1 ? out[0] : out;
}
const big = (v) => BigInt(String(v).split(/\s+/)[0]);
const readBig = (to, sig, args) => big(read(to, sig, args));
const chainTime = () => Number(BigInt(JSON.parse(cast(['rpc', '--rpc-url', RPC, 'eth_getBlockByNumber', 'latest', 'false'])).timestamp));
const blockNumber = () => Number(BigInt(cast(['block-number', '--rpc-url', RPC])));
const ethBalance = (a) => BigInt(cast(['balance', '--rpc-url', RPC, a]));

const keyDir = fs.mkdtempSync(path.join(os.tmpdir(), 'qz-bell-scenario-'));
const cleanup = () => {
  fs.rmSync(keyDir, {recursive: true, force: true});
  if (CMD === 'run') {
    try {
      if (fs.readFileSync(LOCK_FILE, 'utf8').trim() === String(process.pid)) fs.rmSync(LOCK_FILE, {force: true});
    } catch {
      // no lock
    }
  }
};
process.on('exit', cleanup);
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => process.exit(128 + (os.constants.signals[sig] ?? 1)));

function keystore(name, privateKey) {
  const password = crypto.randomBytes(16).toString('hex');
  const salt = crypto.randomBytes(32);
  const iv = crypto.randomBytes(16);
  const dk = crypto.scryptSync(password, salt, 32, {N: 4096, r: 8, p: 1});
  const c = crypto.createCipheriv('aes-128-ctr', dk.subarray(0, 16), iv);
  const ct = Buffer.concat([c.update(Buffer.from(privateKey.replace(/^0x/, ''), 'hex')), c.final()]);
  const mac = cast(['keccak'], {input: '0x' + Buffer.concat([dk.subarray(16, 32), ct]).toString('hex')}).slice(2);
  const file = path.join(keyDir, `${name}.json`);
  const pw = path.join(keyDir, `${name}.pw`);
  fs.writeFileSync(file, JSON.stringify({version: 3, id: crypto.randomUUID(), crypto: {cipher: 'aes-128-ctr', cipherparams: {iv: iv.toString('hex')}, ciphertext: ct.toString('hex'), kdf: 'scrypt', kdfparams: {dklen: 32, n: 4096, r: 8, p: 1, salt: salt.toString('hex')}, mac}}), {mode: 0o600});
  fs.writeFileSync(pw, password, {mode: 0o600});
  return ['--keystore', file, '--password-file', pw];
}

// ───────────── config and the chain check ─────────────

const CHAIN = Number(cast(['chain-id', '--rpc-url', RPC]));
if (CHAIN !== CHAIN_ID) {
  console.error(`RPC chain ${CHAIN} is not the Robinhood testnet (${CHAIN_ID}); refusing to run`);
  process.exit(2);
}
if (!fs.existsSync(BELL_FILE) || !fs.existsSync(MODELB_FILE)) {
  console.error(`missing ${BELL_FILE} or ${MODELB_FILE}: deploy first (contracts/script/dapps/DeployCloseBell.s.sol, deploy-record.mjs write)`);
  process.exit(2);
}
const dep = JSON.parse(fs.readFileSync(BELL_FILE, 'utf8'));
const modelB = JSON.parse(fs.readFileSync(MODELB_FILE, 'utf8'));
if (dep.chainId !== CHAIN_ID || modelB.chainId !== CHAIN_ID) {
  console.error('deployment files are not for chain 46630');
  process.exit(2);
}
const BELL = dep.contracts.QZCloseBell;
const BOARD = dep.contracts.QZBoardSource;
const MACHINE = dep.dependencies.QZMachine;
const FORGE = dep.dependencies.QZForge;
const QZ = dep.dependencies.qz;
const USDG = dep.dependencies.usdg;
const VAULT = modelB.contracts.QZRewardVault;
const CONVERTER = modelB.contracts.QZConverter;
for (const [n, a] of Object.entries({BELL, BOARD, MACHINE, FORGE, QZ, USDG})) {
  if (cast(['code', '--rpc-url', RPC, a]) === '0x') {
    console.error(`${n} ${a} has no code on this chain`);
    process.exit(2);
  }
}

const actors = {};
for (const name of Object.keys(KEY_ENV)) {
  const key = process.env[KEY_ENV[name]];
  if (!key) {
    console.error(`${KEY_ENV[name]} is not set (load it with: secret env-file <file> ${KEY_ENV[name]}=<secret name>)`);
    process.exit(2);
  }
  const signer = keystore(name, key);
  actors[name] = {signer, address: cast(['wallet', 'address', ...signer])};
}
{
  const dk = process.env.DEPLOYER_PRIVATE_KEY;
  const derived = cast(['keccak'], {input: '0x' + Buffer.from('qz-model-b-public-minter:' + dk.replace(/^0x/, '')).toString('hex')});
  const signer = keystore('public', derived);
  actors.public = {signer, address: cast(['wallet', 'address', ...signer])};
}
const who = (n) => actors[n].address;
const lc = (a) => String(a).toLowerCase();
if (lc(dep.roles.calendar) !== lc(who('deployer')) || lc(dep.roles.poster) !== lc(who('deployer'))) {
  console.error('the deployer key is not the Bell calendar and board poster of the deployment file');
  process.exit(2);
}

// ───────────── proof and state files ─────────────

function writeJsonAtomic(file, data) {
  const tmp = `${file}.${process.pid}.tmp`;
  const fd = fs.openSync(tmp, 'w', 0o644);
  try {
    fs.writeSync(fd, JSON.stringify(data, null, 2) + '\n');
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, file);
}
for (const f of fs.readdirSync(DIR)) if (/closing-bell.*\.\d+\.tmp$/.test(f)) fs.rmSync(path.join(DIR, f), {force: true});

const proof = fs.existsSync(PROOF_FILE) ? JSON.parse(fs.readFileSync(PROOF_FILE, 'utf8')) : {generatedAt: '', chainId: CHAIN_ID, bell: BELL, board: BOARD, steps: []};
const state = fs.existsSync(STATE_FILE) ? JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) : {};
state.pending ||= {};
state.failed ||= {};
state.vars ||= {};
const saveState = () => writeJsonAtomic(STATE_FILE, state);
const has = (id) => proof.steps.some((s) => s.id === id);
const stepOf = (id) => proof.steps.find((s) => s.id === id);
for (const id of Object.keys(state.pending)) if (has(id)) delete state.pending[id];

function pushStep(step) {
  if (has(step.id)) throw new Error(`proof already has step ${step.id}`);
  proof.steps.push({...step, recordedAt: new Date().toISOString()});
  proof.generatedAt = new Date().toISOString();
  writeJsonAtomic(PROOF_FILE, proof);
  delete state.pending[step.id];
  delete state.failed[step.id];
  saveState();
}

// A value read once and kept: a resumed run must not re-read a balance after the transaction it brackets.
function once(key, fn) {
  if (!(key in state.vars)) {
    state.vars[key] = String(fn());
    saveState();
  }
  return state.vars[key];
}

// ───────────── transactions ─────────────

const receiptOf = (hash) => JSON.parse(cast(['rpc', '--rpc-url', RPC, 'eth_getTransactionReceipt', hash]));
const POSSIBLY_ACCEPTED = /already (known|imported)|known transaction|already in the mempool|replacement transaction underpriced|nonce (is )?too low/i;
const txNonce = (raw) => Number(BigInt(JSON.parse(cast(['decode-tx', raw])).nonce));
const accountNonce = (actor) => Number(cast(['nonce', '--rpc-url', RPC, '--block', 'latest', who(actor)]));

async function landed(id, p) {
  let r = receiptOf(p.txHash);
  let refusal = null;
  if (!r) {
    try {
      cast(['publish', '--rpc-url', RPC, '--async', p.raw]);
    } catch (e) {
      if (!POSSIBLY_ACCEPTED.test(e.revert)) refusal = e;
    }
    const nonce = txNonce(p.raw);
    const deadline = Date.now() + (refusal ? 20_000 : TX_WAIT_MS);
    for (;;) {
      if ((r = receiptOf(p.txHash))) break;
      if (accountNonce(p.actor) > nonce) {
        for (let end = Date.now() + 10_000; !r && Date.now() < end; ) {
          await sleep(1000);
          r = receiptOf(p.txHash);
        }
        if (r) break;
        delete state.pending[id];
        (state.dropped ||= []).push({id, txHash: p.txHash, actor: p.actor, nonce, at: new Date().toISOString()});
        saveState();
        throw new Error(`transaction ${p.txHash} for ${id} never mined: nonce ${nonce} of ${p.actor} was used by another transaction; moved to "dropped" in the state file`);
      }
      if (Date.now() >= deadline) break;
      await sleep(1000);
    }
  }
  if (!r) {
    throw new Error(refusal
      ? `transaction ${p.txHash} for ${id} refused by the node (${refusal.revert}); stays pending, run again`
      : `transaction ${p.txHash} for ${id} not mined after ${TX_WAIT_MS / 1000}s; stays pending, run again`);
  }
  if (String(r.status) !== '0x1') {
    delete state.pending[id];
    saveState();
    throw new Error(`transaction ${r.transactionHash} for ${id} reverted (status ${r.status})`);
  }
  return r;
}

// Sign, write ahead, publish, wait, record. A step already in the proof is skipped; a pending entry is resumed.
async function tx(id, label, actor, to, sig, args, meta, note) {
  if (has(id)) return stepOf(id);
  let p = state.pending[id];
  if (!p) {
    const a = ['mktx', '--rpc-url', RPC];
    if (meta.value !== undefined) a.push('--value', String(meta.value));
    a.push(to);
    if (sig) a.push(sig, ...args.map(String));
    const raw = cast([...a, ...actors[actor].signer]);
    p = {actor, txHash: keccak(raw), raw, at: new Date().toISOString()};
    state.pending[id] = p;
    saveState();
  }
  const r = await landed(id, p);
  const step = {
    id, label, contract: meta.contract, fn: meta.fn || sig, txHash: r.transactionHash,
    blockNumber: Number(BigInt(r.blockNumber)), gasUsed: Number(BigInt(r.gasUsed)), actor: who(actor),
    note: `${actor}: ${note || label}`,
  };
  pushStep(step);
  console.log(`  + ${id.padEnd(34)} ${r.transactionHash}  block ${step.blockNumber}  gas ${step.gasUsed}`);
  return step;
}

// An expected revert, read with eth_call as `actor`. The revert data must start with the selector of one of `errors`
// (error signatures); `any` accepts any revert and records what came back.
function expectRevert(id, label, actor, to, sig, args, errors, meta, note, {any = false} = {}) {
  if (has(id)) return;
  let out = null;
  try {
    out = cast(['call', '--rpc-url', RPC, '--from', who(actor), to, sig, ...args.map(String)]);
  } catch (e) {
    out = e;
  }
  if (!(out instanceof Error)) throw new Error(`${id}: expected a revert (${errors.join(' | ')}) but eth_call returned ${out}`);
  const data = (out.revert.match(/data: \\?"?(0x[0-9a-fA-F]+)/) || out.revert.match(/(0x[0-9a-fA-F]{8,})/) || [])[1];
  const selector = data ? data.slice(0, 10).toLowerCase() : null;
  const wanted = errors.map((e) => ({name: e, selector: cast(['sig', e]).toLowerCase()}));
  const hit = wanted.find((w) => w.selector === selector);
  if (!hit && !any) throw new Error(`${id}: reverted with ${selector} (${out.revert.slice(0, 200)}), expected ${wanted.map((w) => `${w.name}=${w.selector}`).join(' | ')}`);
  pushStep({
    id, label, kind: 'eth_call-revert', contract: meta.contract, fn: meta.fn || sig, actor: who(actor), blockNumber: blockNumber(),
    expectedError: errors[0], error: hit ? hit.name : 'unmatched', decoded: (out.revert.match(/reverted: ([^|]+?)\s*(\||$)/) || [])[1] || null, selector, revertData: data || null, note: `${actor}: ${note || label}`,
  });
  console.log(`  ~ ${id.padEnd(34)} reverts ${hit ? hit.name : selector} (${selector})`);
}

// An on-chain assertion: `actual` is read from the chain when the step runs.
function assertEq(id, label, expected, actualFn, note) {
  if (has(id)) return;
  const actual = String(actualFn());
  const ok = String(expected) === actual;
  pushStep({id, label, kind: 'assert', expected: String(expected), actual, ok, blockNumber: blockNumber(), note: note || label});
  console.log(`  ${ok ? '=' : '!'} ${id.padEnd(34)} expected ${expected} actual ${actual} ${ok ? 'OK' : 'FAIL'}`);
  if (!ok) throw new Error(`assertion ${id} failed: expected ${expected}, actual ${actual}`);
}

async function until(ts, why) {
  for (;;) {
    const now = chainTime();
    if (now >= ts) return;
    if (why && !until.said?.has(why)) {
      (until.said ||= new Set()).add(why);
      console.log(`... waiting ${ts - now}s for ${why} (chain time ${new Date(now * 1000).toISOString()})`);
    }
    await sleep(Math.min((ts - now) * 1000, 8000));
  }
}

// ───────────── reads ─────────────

const qzBal = (a) => readBig(QZ, 'balanceOf(address)(uint256)', [a]);
const usdgBal = (a) => readBig(USDG, 'balanceOf(address)(uint256)', [a]);
const bellView = (sig, args = []) => read(BELL, sig, args);
const heat = (id) => bellView('heatOf(uint256)(uint32,uint32,uint32,uint32,uint8)', [id]).map((v) => big(v)).join(',');
const callOf = (id, s) => {
  const [payer, track, dir, st] = bellView('callOf(uint256,uint32)(address,uint8,uint8,uint8)', [id, s]);
  return `${lc(payer)},${big(track)},${big(dir)},${big(st)}`;
};
const closeStatus = (track, s) => big(bellView('closeOf(uint8,uint32)(uint128,int32,uint32,uint8)', [track, s])[3]);
const ownerOf = (id) => lc(read(MACHINE, 'ownerOf(uint256)(address)', [id]));
const sideEffects = () => {
  const v = {
    lockedPrincipal: readBig(FORGE, 'lockedPrincipal()(uint256)'),
    litCount: readBig(FORGE, 'litCount()(uint256)'),
    notified: [T_M1, T_M2, T_M3].map((t) => readBig(VAULT, 'totalNotified(uint8)(uint256)', [t])).join('|'),
    pot: read(CONVERTER, 'potBalance()(uint256,uint256,uint256)').map((x) => big(x)).join('|'),
    claimable1: readBig(VAULT, 'claimable(uint256,uint8)(uint256)', [1, T_M1]),
  };
  return JSON.stringify(v, (k, x) => (typeof x === 'bigint' ? x.toString() : x));
};

// ───────────── the calendar ─────────────

const profile = dep.profile;
const S = () => Number(state.vars.S);
const open = (k) => S() + 300 * (k - 1);
const cutoff = (k) => open(k) + 210;
const closeTs = (k) => open(k) + 270;
const CLAIM_OPENS = () => closeTs(4) + profile.claimDelay;
const post = (id, track, ts, price, why) =>
  tx(id, `board post: track ${track} ${why}`, 'deployer', BOARD, 'post(uint8,uint64,uint128)', [track, ts, px(price)], {contract: 'QZBoardSource', fn: 'post(uint8,uint64,uint128)'}, `poster posts track ${track} close at ts ${ts}`);
const bellTx = (id, label, actor, sig, args, note) => tx(id, label, actor, BELL, sig, args, {contract: 'QZCloseBell', fn: sig}, note);
const bellRev = (id, label, actor, sig, args, errors, note, opts) => expectRevert(id, label, actor, BELL, sig, args, errors, {contract: 'QZCloseBell', fn: sig}, note, opts);

async function run() {
  const t0 = chainTime();
  console.log(`chain ${CHAIN} time ${new Date(t0 * 1000).toISOString()}  bell ${BELL}  board ${BOARD}`);

  // ── A. deployment ──
  for (const [id, name, label] of [['deploy-board', 'QZBoardSource', 'deploy QZBoardSource'], ['deploy-bell', 'QZCloseBell', 'deploy QZCloseBell']]) {
    if (has(id)) continue;
    const t = dep.transactions[name];
    const r = receiptOf(t.hash);
    if (!r || r.status !== '0x1') throw new Error(`${name} creation ${t.hash} has no successful receipt`);
    pushStep({id, label, contract: name, fn: 'constructor', txHash: t.hash, blockNumber: t.blockNumber, gasUsed: t.gasUsed, actor: who('deployer'), note: `deployer: ${label} (DeployCloseBell.s.sol, recorded from the broadcast)`});
    console.log(`  + ${id.padEnd(34)} ${t.hash}`);
  }
  assertEq('deploy-getters', 'Bell getters equal the deployment inputs', 'ok', () => {
    const want = {
      'machine()(address)': MACHINE, 'forge()(address)': FORGE, 'qz()(address)': QZ, 'usdg()(address)': USDG, 'source()(address)': BOARD,
      'calendar()(address)': dep.roles.calendar, 'treasury()(address)': dep.roles.treasury, 'sponsor()(address)': dep.roles.sponsor,
    };
    for (const [sig, v] of Object.entries(want)) if (lc(read(BELL, sig)) !== lc(v)) return `${sig} = ${read(BELL, sig)} (want ${v})`;
    const nums = {'voidAfter()(uint64)': profile.voidAfter, 'claimDelay()(uint64)': profile.claimDelay, 'minLead()(uint64)': profile.minLead, 'snapshotDelay()(uint64)': profile.snapshotDelay};
    for (const [sig, v] of Object.entries(nums)) if (readBig(BELL, sig) !== BigInt(v)) return `${sig} = ${readBig(BELL, sig)} (want ${v})`;
    if (lc(read(BOARD, 'poster()(address)')) !== lc(dep.roles.poster)) return 'board poster';
    if (readBig(BOARD, 'maxAge()(uint64)') !== BigInt(dep.board.maxAge)) return 'board maxAge';
    return 'ok';
  });

  // ── B. set-up: gas, $QZ, USDG, lighting machine #2 ──
  once('supply0', () => readBig(QZ, 'totalSupply()(uint256)'));
  once('dead0', () => qzBal(DEAD));
  await tx('setup-eth-public', 'fund the public wallet with gas', 'deployer', who('public'), null, [], {contract: 'native', fn: 'transfer', value: 300_000_000_000_000n}, 'deployer sends 0.0003 ETH to the public wallet');
  await tx('setup-qz-public', 'send 150,000 $QZ stand-in to the public wallet', 'user-a', QZ, 'transfer(address,uint256)', [who('public'), 150_000n * E18], {contract: 'MOCK_QZTestToken'}, 'user-a sends 150,000 $QZ to the public wallet (lock + antes)');
  await tx('setup-usdg-treasury', 'mint 500 mock USDG to the treasury', 'deployer', USDG, 'mint(address,uint256)', [who('deployer'), PURSE], {contract: 'MockUSDG'}, 'testnet USDG stand-in mint (the purse)');
  await tx('setup-approve-forge-user-b', 'approve the forge for #2', 'user-b', QZ, 'approve(address,uint256)', [FORGE, 100_000n * E18], {contract: 'MOCK_QZTestToken'}, 'user-b approves 100,000 $QZ to the forge');
  await tx('setup-light-m2', 'light machine #2 (track 4)', 'user-b', FORGE, 'light(uint256)', [2], {contract: 'QZForge'}, 'user-b locks 100,000 $QZ: machine #2 is lit');
  await tx('setup-approve-forge-public', 'approve the forge for #3', 'public', QZ, 'approve(address,uint256)', [FORGE, 100_000n * E18], {contract: 'MOCK_QZTestToken'}, 'public approves 100,000 $QZ to the forge');
  assertEq('setup-machines', 'machines #1 #2 #3 on tracks 9, 4, 5; #1 and #2 lit, #3 not yet', 'true,true,false', () => {
    const lit = (i) => read(FORGE, 'isLit(uint256)(bool)', [i]);
    const tr = [1, 2, 3].map((i) => big(read(MACHINE, 'traitsOf(uint256)(uint8,uint8,bool)', [i])[1])).join(',');
    if (tr !== `${T_M1},${T_M2},${T_M3}`) return `tracks ${tr}`;
    return [lit(1), lit(2), lit(3)].join(',');
  });
  assertEq('setup-isCallable', 'the board serves tracks 9, 4, 5 and not 6 (NFLX) or 7 (RDDT)', 'true,true,true,false,false', () =>
    [T_M1, T_M2, T_M3, 6, 7].map((t) => bellView('isCallable(uint8)(bool)', [t])).join(','));
  once('qz-user-b0', () => qzBal(who('user-b')));
  once('qz-public0', () => qzBal(who('public')));
  once('qz-user-a0', () => qzBal(who('user-a')));
  once('bell-qz0', () => qzBal(BELL));

  // ── C. calendar: board baseline, season 1 ──
  const B = Number(once('baselineTs', () => chainTime() - 10));
  await post('board-baseline-9', T_M1, B, 100, 'baseline');
  await post('board-baseline-4', T_M2, B, 200, 'baseline');
  await post('board-baseline-5', T_M3, B, 300, 'baseline');
  once('S', () => chainTime() + 300); // first opensAt: minLead (120 s) + time for the set-up and the baseline snapshots
  const times = [1, 2, 3, 4].map((k) => `(${open(k)},${cutoff(k)},${closeTs(k)})`);
  const createArgs = [1, 1, B, ANTE, `[${times.join(',')}]`];
  await bellTx('season-create', 'createSeason(1): 4 sessions', 'deployer', 'createSeason(uint16,uint32,uint64,uint128,(uint64,uint64,uint64)[])', createArgs, `calendar creates season 1, ante 1,000 $QZ, first open at ${open(1)}`);
  assertEq('season-getter', 'seasons(1) matches the calendar', `1,4,${B},${ANTE},${CLAIM_OPENS()},true`, () => {
    return bellView('seasons(uint16)(uint32,uint32,uint64,uint128,uint64,bool)', [1]).map((x) => String(x).split(/\s+/)[0]).join(',');
  });
  const sig = 'createSeason(uint16,uint32,uint64,uint128,(uint64,uint64,uint64)[])';
  bellRev('rev-season-exists', 'createSeason(1) again', 'deployer', sig, createArgs, ['SeasonExists(uint16)'], 'a second createSeason for season 1');
  bellRev('rev-season-notcalendar', 'createSeason by a stranger', 'user-a', sig, [2, 5, closeTs(4), ANTE, `[(${chainTime() + 400},${chainTime() + 500},${chainTime() + 600})]`], ['NotCalendar(address)'], 'user-a is not the calendar');
  bellRev('rev-season-toosoon', 'createSeason with a first open inside minLead', 'deployer', sig, [2, 5, closeTs(4), ANTE, `[(${chainTime() + 10},${chainTime() + 100},${chainTime() + 200})]`], ['TooSoon(uint64,uint64)'], 'first opensAt only 10 s ahead, minLead is 120 s');
  for (const [t, p] of [[T_M1, 'a'], [T_M2, 'b'], [T_M3, 'r']]) {
    await until(B + profile.snapshotDelay + 2, 'baseline snapshot delay');
    await bellTx(`baseline-${t}`, `snapshotBaseline(1, track ${t})`, 'deployer', 'snapshotBaseline(uint16,uint8,uint256)', [1, t, B], `anyone records the season-1 baseline of track ${t} (machine ${p})`);
  }
  bellRev('rev-baseline-again', 'snapshotBaseline twice', 'user-a', 'snapshotBaseline(uint16,uint8,uint256)', [1, T_M1, B], ['BaselineAlreadySet(uint16,uint8)'], 'baseline of track 9 is already set');
  bellRev('rev-baseline-notcallable', 'snapshotBaseline for NFLX', 'user-a', 'snapshotBaseline(uint16,uint8,uint256)', [1, T_NOTCALLABLE, B], ['NotCallable(uint8)'], 'track 6 is not on the board');
  assertEq('season-baselines', 'baselines are the board entries', `${px(100)},${px(200)},${px(300)}`, () => [T_M1, T_M2, T_M3].map((t) => big(bellView('baselineOf(uint16,uint8)(uint128)', [1, t]))).join(','));

  // ── D. session 1: calls from 3 machines on 3 tracks ──
  await until(open(1) - 25, 'session 1 to open');
  bellRev('rev-call-before-open', 'call before opensAt', 'user-b', 'call(uint256,uint32,uint8,uint8)', [1, 1, T_M1, UP], ['WindowClosed(uint64,uint64)'], `session 1 opens at ${open(1)}`);
  await until(open(1) + 1);
  bellRev('rev-call-no-allowance', 'call with no allowance', 'user-b', 'call(uint256,uint32,uint8,uint8)', [1, 1, T_M1, UP], ['ERC20InsufficientAllowance(address,uint256,uint256)', 'InsufficientAllowance()'], 'user-b has not approved the Bell yet', {any: true});
  await tx('s1-approve-user-b', 'approve the Bell ($QZ)', 'user-b', QZ, 'approve(address,uint256)', [BELL, 50_000n * E18], {contract: 'MOCK_QZTestToken'}, 'user-b approves 50,000 $QZ to the Bell');
  await bellTx('s1-call-m1', 'call(#1, session 1, track 9, UP)', 'user-b', 'call(uint256,uint32,uint8,uint8)', [1, 1, T_M1, UP], 'machine #1 calls UP; the ante is pulled');
  await bellTx('s1-call-m2', 'call(#2, session 1, track 4, DOWN)', 'user-b', 'call(uint256,uint32,uint8,uint8)', [2, 1, T_M2, DOWN], 'machine #2 calls DOWN');
  bellRev('rev-call-unlit', 'call on an unlit machine', 'public', 'call(uint256,uint32,uint8,uint8)', [3, 1, T_M3, UP], ['NotLit(uint256)'], 'machine #3 is not lit yet');
  await tx('s1-light-m3', 'light machine #3 (track 5)', 'public', FORGE, 'light(uint256)', [3], {contract: 'QZForge'}, 'public locks 100,000 $QZ: machine #3 is lit');
  await tx('s1-approve-public', 'approve the Bell ($QZ)', 'public', QZ, 'approve(address,uint256)', [BELL, 50_000n * E18], {contract: 'MOCK_QZTestToken'}, 'public approves 50,000 $QZ to the Bell');
  await bellTx('s1-call-m3', 'call(#3, session 1, track 5, UP)', 'public', 'call(uint256,uint32,uint8,uint8)', [3, 1, T_M3, UP], 'machine #3 calls UP');
  once('sideEffects0', sideEffects);
  bellRev('rev-call-notowner', 'call by a non-owner', 'user-a', 'call(uint256,uint32,uint8,uint8)', [1, 1, T_M1, UP], ['NotOwner(address)'], 'user-a does not own machine #1');
  bellRev('rev-call-wrongtrack', 'call on the wrong track', 'user-b', 'call(uint256,uint32,uint8,uint8)', [1, 1, T_M3, UP], ['WrongTrack(uint8,uint8)'], 'machine #1 is on track 9, not 5');
  bellRev('rev-call-twice', 'second call in the same session', 'user-b', 'call(uint256,uint32,uint8,uint8)', [1, 1, T_M1, DOWN], ['AlreadyCalled(uint256,uint32)'], 'one call per machine per session');
  assertEq('s1-antes', 'antes pulled: Bell +3,000, user-b -2,000, public -1,000; openAntes 3,000', `${3000n * E18},${2000n * E18},${1000n * E18},${3000n * E18},${3000n * E18}`, () => [
    qzBal(BELL) - BigInt(state.vars['bell-qz0']),
    BigInt(state.vars['qz-user-b0']) - qzBal(who('user-b')),
    BigInt(state.vars['qz-public0']) - qzBal(who('public')) - 100_000n * E18,
    big(bellView('openAntes()(uint256)')),
    big(bellView('totalAnteIn()(uint256)')),
  ].join(','), 'user-b was measured after its 100,000 lock; the public wallet before its lock (so the lock is taken off)');
  assertEq('s1-callOf', 'callOf(#1,1) = payer user-b, track 9, UP, Open', `${lc(who('user-b'))},${T_M1},${UP},1`, () => callOf(1, 1));
  await until(cutoff(1) + 2, 'session 1 cutoff');
  bellRev('rev-call-after-cutoff', 'call at or after the cutoff', 'user-b', 'call(uint256,uint32,uint8,uint8)', [2, 1, T_M2, DOWN], ['WindowClosed(uint64,uint64)'], `cutoff was ${cutoff(1)}`);

  // ── E. session 1: board prices, snapshot, settle ──
  await until(closeTs(1) + 3, 'session 1 close');
  await post('s1-post-9', T_M1, closeTs(1), 110, 'close 110 (up)');
  await post('s1-post-4', T_M2, closeTs(1), 210, 'close 210 (up)');
  await post('s1-post-5', T_M3, closeTs(1), 290, 'close 290 (down)');
  bellRev('rev-snapshot-tooearly', 'snapshot before closeTs + snapshotDelay', 'user-a', 'snapshot(uint8,uint32,uint256)', [T_M1, 1, closeTs(1)], ['TooEarly(uint64)'], 'snapshotDelay is 60 s');
  bellRev('rev-snapshot-outoforder', 'snapshot of session 2 before session 1', 'user-a', 'snapshot(uint8,uint32,uint256)', [T_M1, 2, closeTs(1)], ['OutOfOrder(uint32,uint32)'], 'sessions snapshot in order per track');
  bellRev('rev-settle-early', 'settle before the snapshot', 'user-a', 'settle(uint256,uint32)', [1, 1], ['NotSettleable(uint256,uint32)'], 'no snapshot yet');
  await until(closeTs(1) + profile.snapshotDelay + 2, 'session 1 snapshots');
  for (const t of [T_M1, T_M2, T_M3]) await bellTx(`s1-snapshot-${t}`, `snapshot(track ${t}, session 1)`, 'deployer', 'snapshot(uint8,uint32,uint256)', [t, 1, closeTs(1)], 'third party records the close');
  assertEq('s1-closes', 'session 1 closes: track 9 Up, 4 Up, 5 Down', `${STATUS.Up},${STATUS.Up},${STATUS.Down}`, () => [T_M1, T_M2, T_M3].map((t) => closeStatus(t, 1)).join(','));
  for (const id of [1, 2, 3]) await bellTx(`s1-settle-${id}`, `settle(#${id}, session 1)`, 'deployer', 'settle(uint256,uint32)', [id, 1], `third party settles #${id}`);
  bellRev('rev-settle-twice', 'second settle', 'user-a', 'settle(uint256,uint32)', [1, 1], ['AlreadySettled(uint256,uint32)'], 'a call settles once');
  assertEq('s1-burn', 'dead address +3,000 $QZ, totalBurned 3,000, openAntes 0', `${3000n * E18},${3000n * E18},0,0`, () => [
    qzBal(DEAD) - BigInt(state.vars.dead0), big(bellView('totalBurned()(uint256)')), big(bellView('openAntes()(uint256)')), big(bellView('totalRefunded()(uint256)')),
  ].join(','), 'the ante of a win and of two losses went to 0x...dEaD');
  assertEq('s1-heat', 'heat: #1 win (streak 1), #2 loss, #3 loss; #1 has 1 point', '1,1,1,0,1|0,0,0,1,0|0,0,0,1,0|1', () =>
    [heat(1), heat(2), heat(3), bellView('seasonPoints(uint16,uint256)(uint32)', [1, 1])].join('|').replace(/\s/g, ''));

  // ── F. session 2: a closed-market session for track 9 ──
  await until(open(2) + 1, 'session 2 to open');
  await bellTx('s2-call-m1', 'call(#1, session 2, track 9, UP)', 'user-b', 'call(uint256,uint32,uint8,uint8)', [1, 2, T_M1, UP], 'machine #1 calls UP on a day the poster will not post a price for track 9');
  await until(closeTs(2) + 3, 'session 2 close');
  await post('s2-post-4', T_M2, closeTs(2), 220, 'close 220 (up); track 9 gets no entry: closed market');
  await post('s2-post-5', T_M3, closeTs(2), 280, 'close 280 (down)');
  await until(closeTs(2) + profile.snapshotDelay + 2, 'session 2 snapshots');
  await bellTx('s2-snapshot-9', 'snapshot(track 9, session 2): market closed', 'deployer', 'snapshot(uint8,uint32,uint256)', [T_M1, 2, closeTs(1)], 'hint = the session-1 entry, older than maxAge: Closed');
  await bellTx('s2-snapshot-4', 'snapshot(track 4, session 2)', 'deployer', 'snapshot(uint8,uint32,uint256)', [T_M2, 2, closeTs(2)], 'third party records the close');
  await bellTx('s2-snapshot-5', 'snapshot(track 5, session 2)', 'deployer', 'snapshot(uint8,uint32,uint256)', [T_M3, 2, closeTs(2)], 'third party records the close');
  assertEq('s2-closes', 'session 2 closes: track 9 Closed, 4 Up, 5 Down', `${STATUS.Closed},${STATUS.Up},${STATUS.Down}`, () => [T_M1, T_M2, T_M3].map((t) => closeStatus(t, 2)).join(','));

  // ── G. session 3: #1 UP, #2 UP, #3 UP; track 5 is paused by the poster ──
  await until(open(3) + 1, 'session 3 to open');
  await bellTx('s3-call-m1', 'call(#1, session 3, track 9, UP)', 'user-b', 'call(uint256,uint32,uint8,uint8)', [1, 3, T_M1, UP], 'machine #1 calls UP (session 2 is still open: its settle waits)');
  await bellTx('s3-call-m2', 'call(#2, session 3, track 4, UP)', 'user-b', 'call(uint256,uint32,uint8,uint8)', [2, 3, T_M2, UP], 'machine #2 calls UP');
  await bellTx('s3-call-m3', 'call(#3, session 3, track 5, UP)', 'public', 'call(uint256,uint32,uint8,uint8)', [3, 3, T_M3, UP], 'machine #3 calls UP');
  await until(closeTs(3) + 3, 'session 3 close');
  await post('s3-post-9', T_M1, closeTs(3), 120, 'close 120 (up against the session-1 close of 110)');
  await post('s3-post-4', T_M2, closeTs(3), 215, 'close 215 (down)');
  await tx('s3-pause-5', 'board: pause track 5', 'deployer', BOARD, 'setPaused(uint8,bool)', [T_M3, true], {contract: 'QZBoardSource'}, 'poster flags track 5 paused');
  await until(closeTs(3) + profile.snapshotDelay + 2, 'session 3 snapshots');
  await bellTx('s3-snapshot-9', 'snapshot(track 9, session 3)', 'deployer', 'snapshot(uint8,uint32,uint256)', [T_M1, 3, closeTs(3)], 'third party records the close');
  await bellTx('s3-snapshot-4', 'snapshot(track 4, session 3)', 'deployer', 'snapshot(uint8,uint32,uint256)', [T_M2, 3, closeTs(3)], 'third party records the close');
  bellRev('rev-snapshot-paused', 'snapshot of a paused track', 'deployer', 'snapshot(uint8,uint32,uint256)', [T_M3, 3, closeTs(2)], ['SourceUnavailable()'], 'the source answers Paused: nothing is recorded');
  bellRev('rev-settle-paused', 'settle with no snapshot (#3, session 3)', 'user-a', 'settle(uint256,uint32)', [3, 3], ['NotSettleable(uint256,uint32)'], 'track 5 has no snapshot for session 3');
  bellRev('rev-settle-prevunsettled', 'settle(#1, session 3) while session 2 is open', 'user-a', 'settle(uint256,uint32)', [1, 3], ['PrevUnsettled(uint256,uint32,uint32)'], 'the machine\'s previous call (session 2) is still Open');
  await bellTx('s3-settle-2', 'settle(#2, session 3): loss', 'deployer', 'settle(uint256,uint32)', [2, 3], 'machine #2 called UP, track 4 closed down: ante burned');
  assertEq('s3-heat-2', 'heat #2: 0 streak, 0 wins, 2 losses', '0,0,0,2,0', () => heat(2).replace(/\s/g, ''));

  // ── H. machine transfer between call and settle ──
  once('heat1-before-transfer', () => heat(1));
  await tx('s3-transfer-m1', 'transfer machine #1 from user-b to user-a', 'user-b', MACHINE, 'transferFrom(address,address,uint256)', [who('user-b'), who('user-a'), 1], {contract: 'QZMachine'}, 'machine #1 (calls open in sessions 2 and 3) changes owner');
  assertEq('s3-transfer-check', 'owner of #1 is user-a and its heat did not move', `${lc(who('user-a'))}|${state.vars['heat1-before-transfer']}`, () => `${ownerOf(1)}|${heat(1)}`, 'heat is keyed by machine id and follows the NFT');
  await tx('s4-approve-user-a', 'approve the Bell ($QZ)', 'user-a', QZ, 'approve(address,uint256)', [BELL, 50_000n * E18], {contract: 'MOCK_QZTestToken'}, 'user-a approves 50,000 $QZ to the Bell');

  // ── I. session 4: new owner calls; purse funding ──
  await until(open(4) + 1, 'session 4 to open');
  bellRev('rev-call-formerowner', 'former owner calls #1', 'user-b', 'call(uint256,uint32,uint8,uint8)', [1, 4, T_M1, UP], ['NotOwner(address)'], 'user-b no longer owns machine #1');
  await bellTx('s4-call-m1', 'call(#1, session 4, track 9, UP) by the new owner', 'user-a', 'call(uint256,uint32,uint8,uint8)', [1, 4, T_M1, UP], 'user-a pays the ante for machine #1');
  await bellTx('s4-call-m2', 'call(#2, session 4, track 4, DOWN)', 'user-b', 'call(uint256,uint32,uint8,uint8)', [2, 4, T_M2, DOWN], 'machine #2 calls DOWN');
  await bellTx('s4-call-m3', 'call(#3, session 4, track 5, DOWN)', 'public', 'call(uint256,uint32,uint8,uint8)', [3, 4, T_M3, DOWN], 'machine #3 calls DOWN (track 5 is paused for session 3 only)');
  bellRev('rev-fund-player', 'fundPurse by a player', 'user-a', 'fundPurse(uint16,uint256)', [1, 1], ['NotFunder(address)'], 'only the treasury or the sponsor can fund');
  await tx('s4-approve-usdg-treasury', 'approve the Bell (USDG)', 'deployer', USDG, 'approve(address,uint256)', [BELL, PURSE], {contract: 'MockUSDG'}, 'treasury approves 500 USDG');
  await bellTx('s4-fund-purse', 'fundPurse(1, 500 USDG)', 'deployer', 'fundPurse(uint16,uint256)', [1, PURSE], 'treasury funds the season-1 purse');
  assertEq('s4-purse-funded', 'purseOf(1) funded 500 USDG, paid 0', `${PURSE},0,false`, () => bellView('purseOf(uint16)(uint128,uint128,bool)', [1]).map((x) => String(x).split(/\s+/)[0]).join(','));
  bellRev('rev-claim-early', 'claimPurse before claimOpensAt', 'user-a', 'claimPurse(uint256,uint16)', [1, 1], ['TooEarly(uint64)'], `claims open at ${CLAIM_OPENS()}`);
  await until(closeTs(4) + 3, 'session 4 close');
  await post('s4-post-9', T_M1, closeTs(4), 130, 'close 130 (up)');
  await post('s4-post-4', T_M2, closeTs(4), 205, 'close 205 (down)');
  await post('s4-post-5', T_M3, closeTs(4), 270, 'close 270 (down)');
  await until(closeTs(4) + profile.snapshotDelay + 2, 'session 4 snapshots');
  await bellTx('s4-snapshot-9', 'snapshot(track 9, session 4)', 'deployer', 'snapshot(uint8,uint32,uint256)', [T_M1, 4, closeTs(4)], 'third party records the close');
  await bellTx('s4-snapshot-4', 'snapshot(track 4, session 4)', 'deployer', 'snapshot(uint8,uint32,uint256)', [T_M2, 4, closeTs(4)], 'third party records the close');

  // ── J. void paths and the ordered settles ──
  await until(closeTs(2) + profile.voidAfter, 'closeTs2 + voidAfter');
  bellRev('rev-void-after-snapshot', 'voidExpired(#1, session 2) after a snapshot exists', 'user-a', 'voidExpired(uint256,uint32)', [1, 2], ['NotVoidable(uint256,uint32)'], 'session 2 has a Closed snapshot, so settle is the only way out');
  once('qz-user-b-before-refund', () => qzBal(who('user-b')));
  await bellTx('s2-settle-1', 'settle(#1, session 2): refund', 'deployer', 'settle(uint256,uint32)', [1, 2], 'closed market: the ante goes back to the payer (user-b), not to the new owner');
  assertEq('s2-refund', 'refund to the payer user-b (+1,000), heat of #1 unchanged', `${ANTE},${state.vars['heat1-before-transfer']}`, () => `${qzBal(who('user-b')) - BigInt(state.vars['qz-user-b-before-refund'])},${heat(1)}`.replace(/\s/g, ''));
  bellRev('rev-settle-prevunsettled-4', 'settle(#1, session 4) while session 3 is open', 'user-a', 'settle(uint256,uint32)', [1, 4], ['PrevUnsettled(uint256,uint32,uint32)'], 'settles go in call order per machine');
  await bellTx('s3-settle-1', 'settle(#1, session 3): win, streak 2', 'deployer', 'settle(uint256,uint32)', [1, 3], 'a void session in between does not break the streak');
  await bellTx('s4-settle-1', 'settle(#1, session 4): win, streak 3', 'deployer', 'settle(uint256,uint32)', [1, 4], 'settled for the new owner');
  assertEq('s4-heat-1', 'heat #1: streak 3, best 3, wins 3, losses 0; 6 points', '3,3,3,0,2|6', () => `${heat(1)}|${bellView('seasonPoints(uint16,uint256)(uint32)', [1, 1])}`.replace(/\s/g, ''));

  await until(closeTs(3) + profile.voidAfter, 'closeTs3 + voidAfter');
  once('qz-public-before-void', () => qzBal(who('public')));
  await bellTx('s3-void-3', 'voidExpired(#3, session 3)', 'deployer', 'voidExpired(uint256,uint32)', [3, 3], 'no snapshot at closeTs + voidAfter while the board still says Paused: refund without reading the source');
  assertEq('s3-void-refund', 'refund to public (+1,000)', String(ANTE), () => qzBal(who('public')) - BigInt(state.vars['qz-public-before-void']));
  bellRev('rev-void-twice', 'voidExpired again', 'user-a', 'voidExpired(uint256,uint32)', [3, 3], ['AlreadySettled(uint256,uint32)'], 'already refunded');
  await bellTx('s3-snapshot-5', 'snapshot(track 5, session 3): Expired', 'deployer', 'snapshot(uint8,uint32,uint256)', [T_M3, 3, 0], 'at or after closeTs + voidAfter the snapshot is Expired and reads nothing');
  assertEq('s3-expired', 'closeOf(5, 3) is Expired', String(STATUS.Expired), () => closeStatus(T_M3, 3));
  await tx('s3-unpause-5', 'board: unpause track 5', 'deployer', BOARD, 'setPaused(uint8,bool)', [T_M3, false], {contract: 'QZBoardSource'}, 'poster unflags track 5');
  await bellTx('s4-snapshot-5', 'snapshot(track 5, session 4)', 'deployer', 'snapshot(uint8,uint32,uint256)', [T_M3, 4, closeTs(4)], 'track 5 session 4: 270 against the session-2 close of 280: Down');
  assertEq('s4-closes', 'session 4 closes: track 9 Up, 4 Down, 5 Down', `${STATUS.Up},${STATUS.Down},${STATUS.Down}`, () => [T_M1, T_M2, T_M3].map((t) => closeStatus(t, 4)).join(','));
  await bellTx('s4-settle-3', 'settle(#3, session 4): win, streak restarts at 1', 'deployer', 'settle(uint256,uint32)', [3, 4], 'last settled Up/Down session of #3 is 1 but the track\'s previous one is 2: streak restarts');
  assertEq('s4-heat-3', 'heat #3: streak 1, wins 1, losses 1; 1 point; total season points 7', '1,1,1,1,1|1|7', () => `${heat(3)}|${bellView('seasonPoints(uint16,uint256)(uint32)', [1, 3])}|${bellView('seasonTotalPoints(uint16)(uint64)', [1])}`.replace(/\s/g, ''));

  // ── K. claimOpensAt: frozen points, purse ──
  await until(CLAIM_OPENS() + 3, 'claimOpensAt');
  await bellTx('s4-settle-2', 'settle(#2, session 4) after claimOpensAt: win, no points', 'deployer', 'settle(uint256,uint32)', [2, 4], 'points freeze at claimOpensAt: heat updates, season points do not');
  assertEq('s4-frozen', 'heat #2 streak 1 wins 1 losses 2; points 0; season total still 7', '1,1,1,2,1|0|7', () => `${heat(2)}|${bellView('seasonPoints(uint16,uint256)(uint32)', [1, 2])}|${bellView('seasonTotalPoints(uint16)(uint64)', [1])}`.replace(/\s/g, ''));
  bellRev('rev-fund-late', 'fundPurse after claimOpensAt', 'deployer', 'fundPurse(uint16,uint256)', [1, 1], ['TooLate()'], 'the purse is closed once points freeze');
  once('usdg-user-a-before', () => usdgBal(who('user-a')));
  once('usdg-public-before', () => usdgBal(who('public')));
  await bellTx('claim-1', 'claimPurse(#1, 1)', 'user-b', 'claimPurse(uint256,uint16)', [1, 1], '500 * 6 / 7 USDG to the owner of #1 at claim time (user-a); anyone can trigger it');
  await bellTx('claim-3', 'claimPurse(#3, 1)', 'user-b', 'claimPurse(uint256,uint16)', [3, 1], '500 * 1 / 7 USDG to the owner of #3 (public)');
  assertEq('claim-amounts', 'user-a +428,571,428 and public +71,428,571 USDG', '428571428,71428571', () => `${usdgBal(who('user-a')) - BigInt(state.vars['usdg-user-a-before'])},${usdgBal(who('public')) - BigInt(state.vars['usdg-public-before'])}`);
  bellRev('rev-claim-twice', 'claimPurse twice', 'user-a', 'claimPurse(uint256,uint16)', [1, 1], ['AlreadyClaimed(uint256,uint16)'], 'a machine claims once per season');
  bellRev('rev-claim-nopoints', 'claimPurse with 0 points', 'user-b', 'claimPurse(uint256,uint16)', [2, 1], ['NothingToClaim(uint256,uint16)'], 'machine #2 scored nothing');

  // ── L. final assertions, all re-read from the chain ──
  for (const [id, label, expected, fn] of finalAssertions()) assertEq(id, label, expected(), fn);
  console.log('scenario complete');
}

// Each: [id, label, () => expected, () => actual]
function finalAssertions() {
  const antes = () => big(bellView('openAntes()(uint256)'));
  return [
    ['final-bell-balance', 'Bell $QZ balance == openAntes (nothing else is held)', () => String(antes()), () => qzBal(BELL)],
    ['final-bell-balance-is-counter', 'Bell $QZ balance == bell-qz0 + openAntes (counter and balance agree)', () => String(BigInt(state.vars['bell-qz0']) + antes()), () => qzBal(BELL)],
    ['final-dead-delta', 'dead address delta == totalBurned == 8 antes', () => String(8n * ANTE), () => `${qzBal(DEAD) - BigInt(state.vars.dead0)}`],
    ['final-burned-counter', 'totalBurned == 8,000 $QZ', () => String(8n * ANTE), () => big(bellView('totalBurned()(uint256)'))],
    ['final-ante-conservation', 'totalAnteIn 10,000 == openAntes 0 + totalBurned 8,000 + totalRefunded 2,000', () => `${10n * ANTE},0,${8n * ANTE},${2n * ANTE}`, () => [big(bellView('totalAnteIn()(uint256)')), antes(), big(bellView('totalBurned()(uint256)')), big(bellView('totalRefunded()(uint256)'))].join(',')],
    ['final-supply', '$QZ stand-in totalSupply unchanged', () => state.vars.supply0, () => readBig(QZ, 'totalSupply()(uint256)')],
    ['final-purse', 'purse: funded 500,000,000, paidOut 499,999,999 <= funded, not swept', () => `${PURSE},499999999,false`, () => bellView('purseOf(uint16)(uint128,uint128,bool)', [1]).map((x) => String(x).split(/\s+/)[0]).join(',')],
    ['final-claims-le-funded', 'sum of purse claims (428,571,428 + 71,428,571) <= funded', () => 'true', () => 428571428n + 71428571n <= PURSE && 428571428n + 71428571n === big(bellView('purseOf(uint16)(uint128,uint128,bool)', [1])[1])],
    ['final-bell-usdg', 'Bell USDG balance == funded - paidOut (1 unit of rounding dust)', () => String(PURSE - 499999999n), () => usdgBal(BELL)],
    ['final-no-side-effects', 'forge, vault and converter reads equal the values read after the last lighting', () => state.vars.sideEffects0, () => sideEffects()],
  ];
}

// ───────────── main ─────────────

function takeLock() {
  try {
    const pid = Number(fs.readFileSync(LOCK_FILE, 'utf8').trim());
    if (pid > 0) {
      try {
        process.kill(pid, 0);
        console.error(`another run (pid ${pid}) holds ${LOCK_FILE}`);
        process.exit(2);
      } catch (e) {
        if (e.code === 'EPERM') process.exit(2);
      }
    }
  } catch {
    // no lock file
  }
  fs.writeFileSync(LOCK_FILE, `${process.pid}\n`);
}

if (CMD === 'status') {
  console.log(`${proof.steps.length} steps recorded; pending ${Object.keys(state.pending).length}; failed ${JSON.stringify(state.failed)}`);
  console.log(`S = ${state.vars.S ? new Date(Number(state.vars.S) * 1000).toISOString() : 'not set'}; last step ${proof.steps.at(-1)?.id ?? 'none'}`);
} else if (CMD === 'assert') {
  let bad = 0;
  for (const [id, label, expected, fn] of finalAssertions()) {
    const e = String(expected());
    const a = String(fn());
    console.log(`${e === a ? 'OK  ' : 'FAIL'} ${id}: expected ${e} actual ${a}`);
    if (e !== a) bad++;
  }
  process.exit(bad ? 1 : 0);
} else if (CMD === 'run') {
  takeLock();
  try {
    await run();
  } catch (e) {
    console.error(`FAILED: ${e.message}`);
    const cur = Object.keys(state.pending)[0] || 'run';
    state.failed[cur] = {error: e.message, at: new Date().toISOString()};
    saveState();
    process.exit(1);
  }
} else {
  console.error('usage: scenario.mjs run|status|assert');
  process.exit(2);
}

// Rewrites the generated blocks of docs/CONTRACT.md (event topics, route table, constants) from the SDK sources.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import * as K from '../src/constants.ts';
import { API_PREFIX, routes } from '../src/api.ts';
import { modelBEventTopics } from '../src/generated/model-b/topics.ts';

const block = (name: string, body: string) => ({
  begin: `<!-- BEGIN GENERATED: ${name} -->`,
  end: `<!-- END GENERATED: ${name} -->`,
  body,
});

export function renderEvents(): string {
  const lines = ['| Contract | Event | Signature | topic0 |', '|---|---|---|---|'];
  for (const [key, e] of Object.entries(modelBEventTopics)) {
    const [contract, event] = key.split('.') as [string, string];
    lines.push(`| ${contract} | ${event} | \`${e.signature}\` | \`${e.topic0}\` |`);
  }
  return lines.join('\n');
}

export function renderRoutes(): string {
  const lines = ['| Route | Query | Response type | Summary |', '|---|---|---|---|'];
  for (const [name, r] of Object.entries(routes)) {
    lines.push(`| \`GET ${API_PREFIX}${r.path}\` | see \`RouteQuery<'${name}'>\` | \`RouteResponse<'${name}'>\` | ${r.summary} |`);
  }
  return lines.join('\n');
}

/** Constant table: value from the generated bigint, source section from the NatSpec of QZConstants.sol. */
export function renderConstants(repoRoot: string): string {
  const src = readFileSync(join(repoRoot, 'contracts/src/lib/QZConstants.sol'), 'utf8');
  const lines = ['| Constant | Value | Spec section (NatSpec) |', '|---|---|---|'];
  const re = /((?:[ \t]*\/\/\/[^\n]*\n)+)[ \t]*(?:u?int\d*)\s+internal\s+constant\s+(\w+)/g;
  for (const m of src.matchAll(re)) {
    const name = m[2] as string;
    const doc = (m[1] as string).split('\n').map((l) => l.replace(/^\s*\/\/\/\s?(@dev\s*)?/, '').trim()).join(' ').trim();
    const value = (K as Record<string, unknown>)[name];
    if (value === undefined) continue;
    lines.push(`| \`${name}\` | \`${value}\` | ${doc.replaceAll('|', '/')} |`);
  }
  return lines.join('\n');
}

export function applyBlocks(doc: string, repoRoot: string): string {
  let out = doc;
  for (const b of [block('events', renderEvents()), block('routes', renderRoutes()), block('constants', renderConstants(repoRoot))]) {
    const i = out.indexOf(b.begin);
    const j = out.indexOf(b.end);
    if (i < 0 || j < 0) throw new Error(`docs/CONTRACT.md is missing ${b.begin} / ${b.end}`);
    out = `${out.slice(0, i + b.begin.length)}\n\n${b.body}\n\n${out.slice(j)}`;
  }
  return out;
}

export function writeContractDoc(repoRoot: string): void {
  const path = join(repoRoot, 'docs', 'CONTRACT.md');
  writeFileSync(path, applyBlocks(readFileSync(path, 'utf8'), repoRoot));
}

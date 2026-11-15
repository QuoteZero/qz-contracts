// Node-only helpers (file system). Browser code imports `@qz/sdk/deployment` instead.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseDeployment } from './deployment.ts';
import type { Deployment } from './deployment.ts';

/** Loads and validates `<dir>/<name>.json` (dir defaults to `$QZ_DEPLOYMENTS_DIR` or `./deployments`). */
export function loadDeployment(name: string, dir: string = process.env.QZ_DEPLOYMENTS_DIR ?? 'deployments'): Deployment {
  if (!/^[a-z0-9][a-z0-9-]*$/.test(name)) throw new Error(`bad deployment name: ${name}`);
  const d = parseDeployment(JSON.parse(readFileSync(join(dir, `${name}.json`), 'utf8')));
  if (d.name !== name) throw new Error(`deployment file ${name}.json declares name ${d.name}`);
  return d;
}

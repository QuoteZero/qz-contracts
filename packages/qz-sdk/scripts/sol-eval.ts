// Evaluates the integer constant expressions used in QZConstants.sol / Hooks.sol exactly (rational arithmetic).
// Supported: decimal literals with `_`, `.` and `e` exponent, unit suffixes, identifiers, ( ) * / + - |, type(uint256).max.

type Rat = { n: bigint; d: bigint };

const UNITS: Record<string, bigint> = {
  wei: 1n,
  gwei: 10n ** 9n,
  ether: 10n ** 18n,
  seconds: 1n,
  minutes: 60n,
  hours: 3600n,
  days: 86400n,
  weeks: 604800n,
};

function gcd(a: bigint, b: bigint): bigint {
  a = a < 0n ? -a : a;
  while (b) [a, b] = [b, a % b];
  return a;
}

function rat(n: bigint, d: bigint = 1n): Rat {
  if (d < 0n) {
    n = -n;
    d = -d;
  }
  const g = gcd(n, d) || 1n;
  return { n: n / g, d: d / g };
}

function parseLiteral(text: string): Rat {
  const m = /^(\d[\d_]*)(?:\.(\d+))?(?:e(\d+))?$/.exec(text);
  if (!m) throw new Error(`bad literal ${text}`);
  const intPart = (m[1] as string).replaceAll('_', '');
  const frac = m[2] ?? '';
  const exp = BigInt(m[3] ?? '0');
  let n = BigInt(intPart + frac);
  let d = 10n ** BigInt(frac.length);
  if (exp > 0n) n *= 10n ** exp;
  return rat(n, d);
}

export function evalConstExpr(source: string, lookup: (name: string) => bigint): bigint {
  const expr = source.replace('type(uint256).max', String(2n ** 256n - 1n));
  const tokens = expr.match(/\d[\d_]*(?:\.\d+)?(?:e\d+)?|[A-Za-z_][A-Za-z0-9_.]*|[()*/+\-|]/g);
  if (!tokens) throw new Error(`empty expression: ${source}`);
  let pos = 0;
  const peek = () => tokens[pos];
  const next = () => tokens[pos++];

  function atom(): Rat {
    const t = next();
    if (t === undefined) throw new Error(`unexpected end in ${source}`);
    if (t === '(') {
      const v = orExpr();
      if (next() !== ')') throw new Error(`missing ) in ${source}`);
      return v;
    }
    if (t === '-') {
      const v = atom();
      return rat(-v.n, v.d);
    }
    let value: Rat;
    if (/^\d/.test(t)) {
      value = parseLiteral(t);
      const unit = peek();
      if (unit !== undefined && unit in UNITS) {
        next();
        value = rat(value.n * (UNITS[unit] as bigint), value.d);
      }
    } else {
      value = rat(lookup(t));
    }
    return value;
  }
  function mul(): Rat {
    let v = atom();
    while (peek() === '*' || peek() === '/') {
      const op = next();
      const r = atom();
      v = op === '*' ? rat(v.n * r.n, v.d * r.d) : rat(v.n * r.d, v.d * r.n);
    }
    return v;
  }
  function add(): Rat {
    let v = mul();
    while (peek() === '+' || peek() === '-') {
      const op = next();
      const r = mul();
      v = op === '+' ? rat(v.n * r.d + r.n * v.d, v.d * r.d) : rat(v.n * r.d - r.n * v.d, v.d * r.d);
    }
    return v;
  }
  function orExpr(): Rat {
    let v = add();
    while (peek() === '|') {
      next();
      const r = add();
      if (v.d !== 1n || r.d !== 1n) throw new Error(`| on non-integer in ${source}`);
      v = rat(v.n | r.n);
    }
    return v;
  }
  const result = orExpr();
  if (pos !== tokens.length) throw new Error(`trailing tokens in ${source}`);
  if (result.d !== 1n) throw new Error(`non-integer constant: ${source} = ${result.n}/${result.d}`);
  return result.n;
}

export function stripSolComments(source: string): string {
  return source.replace(/\/\/[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '');
}

export type SolConstant = { name: string; type: string; value: bigint };

/** Parses `<type> internal constant NAME = EXPR;` declarations (integers only). Order = file order. */
export function parseIntegerConstants(
  solSource: string,
  external: (name: string) => bigint = (n) => {
    throw new Error(`unknown identifier ${n}`);
  },
): SolConstant[] {
  const src = stripSolComments(solSource);
  const re = /\b((?:u?int\d*))\s+internal\s+constant\s+(\w+)\s*=\s*([^;]+);/g;
  const out: SolConstant[] = [];
  const known = new Map<string, bigint>();
  for (const m of src.matchAll(re)) {
    const type = m[1] as string;
    const name = m[2] as string;
    const expr = (m[3] as string).replace(/\s+/g, ' ').trim();
    const value = evalConstExpr(expr, (id) => {
      const v = known.get(id);
      return v !== undefined ? v : external(id);
    });
    known.set(name, value);
    out.push({ name, type, value });
  }
  return out;
}

/** `Hooks.sol` flag table: `uint160 internal constant NAME_FLAG = uint160(1 << N);` -> `Hooks.NAME_FLAG`. */
export function parseHookFlags(hooksSource: string): Map<string, bigint> {
  const flags = new Map<string, bigint>();
  for (const m of stripSolComments(hooksSource).matchAll(
    /uint160\s+internal\s+constant\s+(\w+_FLAG)\s*=\s*(?:uint160\()?1\s*<<\s*(\d+)\)?\s*;/g,
  )) {
    flags.set(`Hooks.${m[1]}`, 1n << BigInt(m[2] as string));
  }
  return flags;
}

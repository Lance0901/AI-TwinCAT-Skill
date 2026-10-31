import fs from 'node:fs';
import { MAX_CALL_TIMEOUT_MS, MIN_CALL_TIMEOUT_MS } from './config.js';

export const DEFAULT_TIMEOUT_MS = 120000;
const GRACE_MS = 30000;
export { MAX_CALL_TIMEOUT_MS, MIN_CALL_TIMEOUT_MS };

/** Read tools.json and return Map<name, tool>. */
export function loadToolCatalog(toolsJsonPath) {
  const raw = fs.readFileSync(toolsJsonPath, 'utf8');
  const doc = JSON.parse(raw);
  if (!doc || !Array.isArray(doc.tools)) {
    throw new Error(`${toolsJsonPath}: expected an object with a "tools" array`);
  }
  const map = new Map();
  const byCmdlet = new Map();
  for (const tool of doc.tools) {
    if (!tool || typeof tool.name !== 'string' || typeof tool.cmdlet !== 'string') {
      throw new Error(`${toolsJsonPath}: every tool needs "name" and "cmdlet"`);
    }
    if (map.has(tool.name)) throw new Error(`${toolsJsonPath}: duplicate tool "${tool.name}"`);
    byCmdlet.set(tool.cmdlet, tool.name);
    map.set(tool.name, {
      ...tool,
      inputSchema: tool.inputSchema ?? { type: 'object', properties: {}, required: [], additionalProperties: false }
    });
  }
  map.byCmdlet = byCmdlet;
  map.meta = { generatedAt: doc.generatedAt, moduleVersion: doc.moduleVersion };
  return map;
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function invalid(message, hint) {
  const error = { code: 'INVALID_PARAMS', message };
  if (hint) error.hint = hint;
  return { ok: false, error };
}

/** Returns null when ok, otherwise a human-readable mismatch description. */
function checkType(schema, value, label) {
  if (!schema || typeof schema !== 'object') return null;
  if (Array.isArray(schema.enum) && !schema.enum.includes(value)) {
    return `${label} must be one of ${schema.enum.map((e) => JSON.stringify(e)).join(', ')}, got ${JSON.stringify(value)}`;
  }
  const type = schema.type;
  if (type === undefined || Array.isArray(type)) return null; // {} / union -> any
  switch (type) {
    case 'string':
      return typeof value === 'string' ? null : `${label} must be a string`;
    case 'boolean':
      return typeof value === 'boolean' ? null : `${label} must be a boolean`;
    case 'integer':
      if (!(typeof value === 'number' && Number.isInteger(value))) return `${label} must be an integer`;
      return checkRange(schema, value, label);
    case 'number':
      if (!(typeof value === 'number' && !Number.isNaN(value))) return `${label} must be a number`;
      return checkRange(schema, value, label);
    case 'array': {
      if (!Array.isArray(value)) return `${label} must be an array`;
      if (Number.isInteger(schema.minItems) && value.length < schema.minItems) {
        return `${label} must contain at least ${schema.minItems} item(s)`;
      }
      if (schema.items && typeof schema.items === 'object' && !Array.isArray(schema.items)) {
        for (let i = 0; i < value.length; i++) {
          const problem = checkType(schema.items, value[i], `${label}[${i}]`);
          if (problem) return problem;
        }
      }
      return null;
    }
    case 'object':
      return isPlainObject(value) ? null : `${label} must be an object`;
    default:
      return null;
  }
}

function checkRange(schema, value, label) {
  if (typeof schema.minimum === 'number' && value < schema.minimum) return `${label} must be >= ${schema.minimum}, got ${value}`;
  if (typeof schema.maximum === 'number' && value > schema.maximum) return `${label} must be <= ${schema.maximum}, got ${value}`;
  return null;
}

/**
 * Object values (hashtable / PSCustomObject parameters) end up in PowerShell 5.1's
 * ConvertFrom-Json, which throws on an empty key and on keys that differ only in case
 * ("Cannot convert the JSON string because a dictionary ... contains duplicated keys").
 * Reject those here, recursively, so the whole call does not die with EXECUTION_ERROR.
 * Returns null when ok, otherwise a mismatch description.
 */
function checkObjectKeys(value, label) {
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) {
      const problem = checkObjectKeys(value[i], `${label}[${i}]`);
      if (problem) return problem;
    }
    return null;
  }
  if (!isPlainObject(value)) return null;
  const seen = new Map();
  for (const key of Object.keys(value)) {
    if (key.length === 0) return `${label} contains an empty property name (PowerShell cannot convert it)`;
    const folded = key.toLowerCase();
    const other = seen.get(folded);
    if (other !== undefined) return `${label} contains properties '${other}' and '${key}' that differ only in case (PowerShell cannot convert them)`;
    seen.set(folded, key);
    const problem = checkObjectKeys(value[key], `${label}.${key}`);
    if (problem) return problem;
  }
  return null;
}

/**
 * Whitelist validation against tool.inputSchema.
 * -> { ok: true, params } (null/undefined removed) or { ok: false, error: { code: 'INVALID_PARAMS', ... } }
 */
export function validateParams(tool, args) {
  const schema = tool.inputSchema ?? {};
  const properties = schema.properties ?? {};
  const allowed = Object.keys(properties);
  const required = Array.isArray(schema.required) ? schema.required : [];
  const allowedHint = allowed.length ? `Allowed: ${allowed.join(', ')}` : 'This tool takes no parameters';

  if (args === undefined || args === null) args = {};
  if (!isPlainObject(args)) {
    return invalid(`Arguments for ${tool.name} must be an object`, allowedHint);
  }

  const params = {};
  for (const [key, value] of Object.entries(args)) {
    if (!Object.prototype.hasOwnProperty.call(properties, key)) {
      return invalid(`Unknown parameter '${key}' for ${tool.name}`, allowedHint);
    }
    if (value === null || value === undefined) continue;
    const label = `Parameter '${key}' of ${tool.name}`;
    const problem = checkType(properties[key], value, label) ?? checkObjectKeys(value, label);
    if (problem) return invalid(problem, allowedHint);
    params[key] = value;
  }

  for (const name of required) {
    if (!Object.prototype.hasOwnProperty.call(params, name)) {
      return invalid(`Missing required parameter '${name}' for ${tool.name}`, `Required: ${required.join(', ')}`);
    }
  }

  return { ok: true, params };
}

function num(v) {
  if (v === undefined || v === null) return undefined;
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}

/**
 * Node-side timeout for one call. When the caller passes the cmdlet's own
 * TimeoutSec / TimeoutMs / DurationMs, that budget plus a 30 s grace wins when larger,
 * so the bridge is only killed when the cmdlet itself is stuck.
 * The result is clamped to [MIN_CALL_TIMEOUT_MS, MAX_CALL_TIMEOUT_MS] (1 s .. 2 h): a value
 * above 2^31-1 ms would make setTimeout fire immediately and report BRIDGE_TIMEOUT at once.
 */
export function computeTimeoutMs(tool, args = {}) {
  const base = tool?.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const timeoutSec = num(args?.TimeoutSec);
  const timeoutMs = num(args?.TimeoutMs);
  const durationMs = num(args?.DurationMs);
  const untilTimeoutMs = num(args?.UntilTimeoutMs);

  let result = base;
  if (timeoutSec !== undefined) result = Math.max(result, timeoutSec * 1000 + GRACE_MS);
  if (timeoutMs !== undefined || untilTimeoutMs !== undefined || durationMs !== undefined) {
    result = Math.max(result, (timeoutMs ?? 0) + (untilTimeoutMs ?? 0) + (durationMs ?? 0) + GRACE_MS);
  }
  if (!Number.isFinite(result)) result = MAX_CALL_TIMEOUT_MS;
  return Math.min(Math.max(result, MIN_CALL_TIMEOUT_MS), MAX_CALL_TIMEOUT_MS);
}

/** Wrap a bridge result object as an MCP CallToolResult. */
export function toToolResult(result) {
  const safe = isPlainObject(result)
    ? result
    : { success: false, error: { code: 'INTERNAL_ERROR', message: 'Tool produced a non-object result', raw: result } };
  return {
    content: [{ type: 'text', text: JSON.stringify(safe, null, 2) }],
    isError: safe.success !== true,
    structuredContent: safe
  };
}

/** cmdlet name -> tool name map: catalog entries plus `extra` (composites that are not in the catalog). */
export function buildCmdletNameMap(catalog, extra = {}) {
  const map = new Map(catalog?.byCmdlet ?? []);
  for (const [k, v] of Object.entries(extra)) map.set(k, v);
  // Parameter schemas, so a switch (boolean) is written Name=true and never swallows the next word,
  // and a parameter named outside a cmdlet call (`換一個 -Name`) is recognised (phase2-3.8.md P1).
  const toolParams = new Map();
  const anyParam = new Map();
  if (catalog && typeof catalog[Symbol.iterator] === 'function') {
    for (const [toolName, tool] of catalog) {
      const props = tool?.inputSchema?.properties ?? {};
      toolParams.set(toolName, props);
      for (const [p, s] of Object.entries(props)) {
        if (!anyParam.has(p)) anyParam.set(p, []);
        anyParam.get(p).push(s);
      }
    }
  }
  map.toolParams = toolParams;
  map.anyParam = anyParam;
  return map;
}

// A cmdlet name, or a parameter named on its own (`-Name`) after a blank, an opening bracket or a separator.
const TOKEN_RE = /\b([A-Z][a-z]+-Tc[A-Za-z]+)\b|(?<=^|[\s(（,，;；:：、/「])-([A-Z][A-Za-z]+)\b/g;
// `-Param` or `-Param:$false`; the name must end at a blank, a bracket or punctuation.
const PARAM_NAME_RE = /^-([A-Z][A-Za-z]+)(?::\$(true|false)\b)?(?=$|[\s,;:()（）。，；：、.])/;
const QUOTED = `(?:'[^']*'|"[^"]*")`;
// The value after the name: $true / $false, one quoted string or a comma-joined list of them
// ('a','b' = a PowerShell array), a <placeholder>, or a bare word.
const PARAM_VALUE_RE = new RegExp(
  `^\\s+(?:\\$(true|false)\\b|(${QUOTED}(?:\\s*,\\s*${QUOTED})*)|(<[^>]+>)|([A-Za-z0-9_\\\\:/][A-Za-z0-9_.\\\\:/-]*))`
);

function schemaFlags(schemas) {
  const list = (schemas ?? []).filter(Boolean);
  return {
    known: list.length > 0,
    isBool: list.length > 0 && list.every((s) => s.type === 'boolean'),
    isArray: list.some((s) => s.type === 'array'),
    enumHas: (v) => list.some((s) => Array.isArray(s.enum) && s.enum.includes(v))
  };
}

/**
 * Parse one `-Param [value]` at text[pos] ('-') -> { text, end } or null.
 * mode 'call': right after a cmdlet name (bare words are values unless the parameter is a switch);
 * mode 'alone': a parameter named in prose (a bare word is a value only when it is in the enum).
 */
function parseParam(text, pos, schemas, mode) {
  const nm = PARAM_NAME_RE.exec(text.slice(pos));
  if (!nm) return null;
  const name = nm[1];
  const f = schemaFlags(schemas);
  let end = pos + nm[0].length;
  if (nm[2] !== undefined) return { text: `${name}=${nm[2]}`, end };
  const vm = PARAM_VALUE_RE.exec(text.slice(end));
  if (vm && vm[1] !== undefined) return { text: `${name}=${vm[1]}`, end: end + vm[0].length };
  if (vm && vm[2] !== undefined && !f.isBool) {
    const items = vm[2].match(new RegExp(QUOTED, 'g'));
    const value = items.length > 1 || f.isArray ? `[${items.join(',')}]` : items[0];
    return { text: `${name}=${value}`, end: end + vm[0].length };
  }
  if (vm && vm[3] !== undefined && !f.isBool) return { text: `${name}=${vm[3]}`, end: end + vm[0].length };
  if (vm && vm[4] !== undefined && !f.isBool) {
    // a sentence-ending '.' is not part of the value
    let word = vm[4];
    let len = vm[0].length;
    if (word.length > 1 && word.endsWith('.')) { word = word.slice(0, -1); len -= 1; }
    if (mode === 'call' || f.enumHas(word)) return { text: `${name}=${word}`, end: end + len };
  }
  if (f.isBool) return { text: `${name}=true`, end };
  if (mode === 'alone') return { text: name, end };
  // after a cmdlet: an unknown parameter (composite tool) is a switch; a known value parameter needs a value
  return { text: f.known ? `${name}=<${name}>` : `${name}=true`, end };
}

/**
 * Replace PowerShell cmdlet names (and their ` -Param value` tails) in a hint with MCP tool names,
 * and parameters named on their own (`-Name`) with the MCP spelling. The module writes the
 * PowerShell form (CLI users read it as is); the MCP server rewrites it here.
 */
export function rewriteHintCmdletNames(hint, nameMap) {
  if (typeof hint !== 'string' || !nameMap) return hint;
  const toolParams = nameMap.toolParams ?? new Map();
  const anyParam = nameMap.anyParam ?? new Map();
  let out = '';
  let last = 0;
  TOKEN_RE.lastIndex = 0;
  let m;
  while ((m = TOKEN_RE.exec(hint)) !== null) {
    if (m[1] !== undefined) {
      const tool = nameMap.get(m[1]);
      if (tool === undefined) continue;
      const props = toolParams.get(tool);
      out += hint.slice(last, m.index) + tool;
      let end = m.index + m[1].length;
      for (;;) {
        if (!/^\s-/.test(hint.slice(end, end + 2))) break;
        const name = /^\s-([A-Z][A-Za-z]+)/.exec(hint.slice(end))?.[1];
        const schema = props && name && Object.prototype.hasOwnProperty.call(props, name) ? [props[name]] : props ? [] : undefined;
        const pp = parseParam(hint, end + 1, schema, 'call');
        if (!pp) break;
        out += ` ${pp.text}`;
        end = pp.end;
      }
      last = end;
      TOKEN_RE.lastIndex = end;
    } else {
      if (!anyParam.has(m[2])) continue;
      const pp = parseParam(hint, m.index, anyParam.get(m[2]), 'alone');
      if (!pp) continue;
      out += hint.slice(last, m.index) + pp.text;
      last = pp.end;
      TOKEN_RE.lastIndex = pp.end;
    }
  }
  return out + hint.slice(last);
}

// Result fields whose text names cmdlets for the caller to run (phase2-3.8.md P1). Every string
// below such a key is rewritten; other fields (code, paths, PLC values) are left alone.
const REWRITE_KEYS = new Set([
  'hint', 'message', 'verifyHint', 'warning', 'warnings', 'restore', 'restoreNote', 'how',
  'buildRequired', 'stateWarning', 'note', 'locateHint'
]);

function rewriteDeep(value, nameMap, depth) {
  if (typeof value === 'string') return rewriteHintCmdletNames(value, nameMap);
  if (value === null || typeof value !== 'object' || depth > 8) return value;
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) value[i] = rewriteDeep(value[i], nameMap, depth + 1);
  } else {
    for (const k of Object.keys(value)) value[k] = rewriteDeep(value[k], nameMap, depth + 1);
  }
  return value;
}

/** Rewrite hint / message / warning-like strings anywhere in a result (depth <= 8), in place. */
export function rewriteResultHints(result, nameMap, depth = 0) {
  if (result === null || typeof result !== 'object' || depth > 8) return result;
  if (Array.isArray(result)) {
    for (const item of result) rewriteResultHints(item, nameMap, depth + 1);
    return result;
  }
  for (const [k, v] of Object.entries(result)) {
    if (REWRITE_KEYS.has(k) && (depth > 0 || k !== 'hint')) result[k] = rewriteDeep(v, nameMap, depth + 1);
    else rewriteResultHints(v, nameMap, depth + 1);
  }
  return result;
}

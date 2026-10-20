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
  return map;
}

const CMDLET_RE = /\b([A-Z][a-z]+-Tc[A-Za-z]+)\b/g;
// ` -Param` or ` -Param value` right after a replaced cmdlet name; the value must not be another switch.
const PARAM_RE = /^\s-([A-Z][A-Za-z]+)(?=\s|$|[,;:()。，；：])(?:\s+(<[^>]+>|[A-Za-z0-9_.\:/][A-Za-z0-9_.\:/-]*))?/;

/** Replace PowerShell cmdlet names (and their ` -Param value` tails) in a hint with MCP tool names. */
export function rewriteHintCmdletNames(hint, nameMap) {
  if (typeof hint !== 'string' || !nameMap) return hint;
  let out = '';
  let last = 0;
  CMDLET_RE.lastIndex = 0;
  let m;
  while ((m = CMDLET_RE.exec(hint)) !== null) {
    const tool = nameMap.get(m[1]);
    if (tool === undefined) continue;
    out += hint.slice(last, m.index) + tool;
    let end = m.index + m[1].length;
    for (;;) {
      const pm = PARAM_RE.exec(hint.slice(end));
      if (!pm) break;
      out += ` ${pm[1]}=${pm[2] ?? 'true'}`;
      end += pm[0].length;
    }
    last = end;
    CMDLET_RE.lastIndex = end;
  }
  return out + hint.slice(last);
}

/** Rewrite error.hint / data.hint strings anywhere in a result (depth <= 8), in place. */
export function rewriteResultHints(result, nameMap, depth = 0) {
  if (result === null || typeof result !== 'object' || depth > 8) return result;
  if (Array.isArray(result)) {
    for (const item of result) rewriteResultHints(item, nameMap, depth + 1);
    return result;
  }
  const err = result.error;
  if (err && typeof err === 'object' && typeof err.hint === 'string') err.hint = rewriteHintCmdletNames(err.hint, nameMap);
  if (typeof result.hint === 'string' && depth > 0) result.hint = rewriteHintCmdletNames(result.hint, nameMap);
  for (const v of Object.values(result)) rewriteResultHints(v, nameMap, depth + 1);
  return result;
}

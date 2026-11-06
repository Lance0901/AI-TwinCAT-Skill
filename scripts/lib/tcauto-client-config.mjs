#!/usr/bin/env node
// Registers / unregisters the tcauto MCP server in one MCP client config file (#20). Used by
// Install-TcAuto.ps1 (run with the node.exe it installs); zero dependencies, so it runs from the
// release zip (lib\tcauto-client-config.mjs) as well as from the checkout (scripts\lib\).
//
//   node tcauto-client-config.mjs set    --client <claude-code|claude-desktop|codex> --file <path> --command <exe> --arg <a> [--arg <b> ...] [--stamp <s>]
//   node tcauto-client-config.mjs remove --client <...> --file <path> --owned-root <install root> [--stamp <s>]
//
// Only the tcauto entry changes; every other server, key and table is kept:
//   claude-code     ~/.claude.json, top-level mcpServers.tcauto = {type: 'stdio', command, args, env: {}}
//                   (user scope; projects[*].mcpServers are not touched)
//   claude-desktop  %APPDATA%\Claude\claude_desktop_config.json, mcpServers.tcauto = {command, args}
//   codex           ~/.codex/config.toml, table [mcp_servers.tcauto] (and its sub-tables) with command / args
// Before a file is changed it is copied to <file>.bak-<stamp>. JSON is written as UTF-8 without BOM,
// with the indent and line ending of the original. The new file is written to a temp file next to
// it and renamed over it. `remove` removes the entry only when its command is below --owned-root (an
// entry that points elsewhere, e.g. a developer checkout, is left and reported as 'foreign').
// Prints one JSON line {success, data | error}; exit code 0 / 1.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SERVER_NAME = 'tcauto';
export const CLIENTS = Object.freeze({ 'claude-code': 'json', 'claude-desktop': 'json', codex: 'toml' });

export class ConfigError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/** The tcauto entry a client gets. */
export function entryFor(client, command, args) {
  if (client === 'claude-code') return { type: 'stdio', command, args: [...args], env: {} };
  return { command, args: [...args] };
}

function sameValue(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

/** true when a command path lies below root (case-insensitive, Windows paths). */
export function isOwned(command, root) {
  if (typeof command !== 'string' || !command || typeof root !== 'string' || !root) return false;
  const norm = (p) => path.win32.resolve(p).replace(/[\\/]+$/, '').toLowerCase();
  return norm(command).startsWith(norm(root) + '\\');
}

// ------------------------------------------------------------------ JSON

function parseJson(text, file) {
  const body = text.replace(/^\uFEFF/, '');
  if (!body.trim()) return {};
  let obj;
  try {
    obj = JSON.parse(body);
  } catch (err) {
    throw new ConfigError('CONFIG_INVALID', `${file} is not valid JSON (${err.message}); it was not changed`);
  }
  if (!isPlainObject(obj)) throw new ConfigError('CONFIG_INVALID', `${file}: the top level is not a JSON object; it was not changed`);
  return obj;
}

function formatJson(obj, original) {
  const m = /\n([ \t]+)"/.exec(original ?? '');
  const indent = m ? m[1] : 2;
  const eol = /\r\n/.test(original ?? '') ? '\r\n' : '\n';
  return JSON.stringify(obj, null, indent).replace(/\n/g, eol) + eol;
}

/** -> { text, action: 'added' | 'updated' | 'unchanged', previous } */
export function setJson(text, file, client, command, args) {
  const obj = parseJson(text ?? '', file);
  if (obj.mcpServers !== undefined && !isPlainObject(obj.mcpServers)) {
    throw new ConfigError('CONFIG_INVALID', `${file}: mcpServers is not an object; it was not changed`);
  }
  const servers = obj.mcpServers ?? {};
  const previous = servers[SERVER_NAME] ?? null;
  const entry = entryFor(client, command, args);
  if (previous !== null && sameValue(previous, entry)) return { text, action: 'unchanged', previous };
  servers[SERVER_NAME] = entry;
  obj.mcpServers = servers;
  return { text: formatJson(obj, text), action: previous === null ? 'added' : 'updated', previous };
}

/** -> { text, action: 'removed' | 'absent' | 'foreign', previous } */
export function removeJson(text, file, ownedRoot) {
  const obj = parseJson(text ?? '', file);
  const servers = isPlainObject(obj.mcpServers) ? obj.mcpServers : null;
  const previous = servers?.[SERVER_NAME] ?? null;
  if (previous === null) return { text, action: 'absent', previous };
  if (!isOwned(previous?.command, ownedRoot)) return { text, action: 'foreign', previous };
  delete servers[SERVER_NAME];
  return { text: formatJson(obj, text), action: 'removed', previous };
}

// ------------------------------------------------------------------ TOML (only what [mcp_servers.tcauto] needs)

const HEADER_RE = /^\s*\[(?!\[)\s*([^\]]*?)\s*\](?!\])\s*(?:#.*)?$/;
const ARRAY_HEADER_RE = /^\s*\[\[\s*([^\]]*?)\s*\]\]\s*(?:#.*)?$/;

/** dotted TOML key -> parts ('mcp_servers."tcauto"' -> ['mcp_servers', 'tcauto']) */
function keyParts(key) {
  const parts = [];
  const re = /\s*(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|([A-Za-z0-9_-]+))\s*(?:\.|$)/y;
  let m;
  let pos = 0;
  while (pos < key.length && (m = re.exec(key))) {
    parts.push(m[1] ?? m[2] ?? m[3]);
    pos = re.lastIndex;
    if (m[0].length === 0) break;
  }
  return pos >= key.length ? parts : null;
}

/** TOML string for a value: literal string when possible (Windows paths need no escaping), else basic. */
export function tomlString(s) {
  if (!/['\u0000-\u001f\u007f]/.test(s)) return `'${s}'`;
  return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/[\u0000-\u001f\u007f]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')) + '"';
}

function tomlSection(command, args, eol) {
  return [`[mcp_servers.${SERVER_NAME}]`, `command = ${tomlString(command)}`, `args = [${args.map(tomlString).join(', ')}]`].join(eol) + eol;
}

/** first string value of `command = ...` in a removed section, for ownership / reporting */
function tomlCommandOf(sectionText) {
  const m = /^\s*command\s*=\s*(?:'([^']*)'|"((?:[^"\\]|\\.)*)")/m.exec(sectionText);
  if (!m) return null;
  if (m[1] !== undefined) return m[1];
  try {
    return JSON.parse(`"${m[2]}"`);
  } catch {
    return m[2];
  }
}

/**
 * Splits a TOML text into the tcauto sections ([mcp_servers.tcauto] and [mcp_servers.tcauto.*],
 * header to the next header) and the rest. A tcauto defined any other way (inline table in
 * [mcp_servers], dotted key at the top) is refused rather than guessed at.
 */
function splitToml(text, file) {
  const lines = text.split(/\r?\n/);
  const keep = [];
  const removed = [];
  let table = []; // current table key parts
  let inTcauto = false;
  for (const line of lines) {
    const arr = ARRAY_HEADER_RE.exec(line);
    const hdr = arr ? null : HEADER_RE.exec(line);
    if (arr || hdr) {
      const parts = keyParts((arr ?? hdr)[1]);
      if (parts === null) throw new ConfigError('CONFIG_UNSUPPORTED', `${file}: cannot read the table header ${line.trim()}; it was not changed`);
      table = parts;
      inTcauto = parts.length >= 2 && parts[0] === 'mcp_servers' && parts[1] === SERVER_NAME;
    } else if (!inTcauto) {
      const km = /^\s*((?:"(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_-]+)(?:\s*\.\s*(?:"(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_-]+))*)\s*=/.exec(line);
      if (km) {
        const full = [...table, ...(keyParts(km[1]) ?? [])];
        if (full.length >= 2 && full[0] === 'mcp_servers' && full[1] === SERVER_NAME) {
          throw new ConfigError('CONFIG_UNSUPPORTED', `${file}: ${SERVER_NAME} is defined as a key (${line.trim()}), not as a [mcp_servers.${SERVER_NAME}] table; edit it by hand. The file was not changed`);
        }
      }
    }
    (inTcauto ? removed : keep).push(line);
  }
  return { keep, removed };
}

function joinLines(lines, eol) {
  // drop trailing empty lines, end with one line break
  const out = [...lines];
  while (out.length && out[out.length - 1].trim() === '') out.pop();
  return out.length ? out.join(eol) + eol : '';
}

/** -> { text, action, previous } (previous: the removed section text, or null) */
export function setToml(text, file, command, args) {
  const src = (text ?? '').replace(/^\uFEFF/, '');
  const eol = /\r\n/.test(src) ? '\r\n' : '\n';
  const { keep, removed } = splitToml(src, file);
  const previous = removed.length ? joinLines(removed, eol) : null;
  const section = tomlSection(command, args, eol);
  if (previous !== null && previous === section) return { text, action: 'unchanged', previous };
  const rest = joinLines(keep, eol);
  return { text: (rest ? rest + eol : '') + section, action: previous === null ? 'added' : 'updated', previous };
}

/** -> { text, action: 'removed' | 'absent' | 'foreign', previous } */
export function removeToml(text, file, ownedRoot) {
  const src = (text ?? '').replace(/^\uFEFF/, '');
  const eol = /\r\n/.test(src) ? '\r\n' : '\n';
  const { keep, removed } = splitToml(src, file);
  if (!removed.length) return { text, action: 'absent', previous: null };
  const previous = joinLines(removed, eol);
  if (!isOwned(tomlCommandOf(previous), ownedRoot)) return { text, action: 'foreign', previous };
  return { text: joinLines(keep, eol), action: 'removed', previous };
}

// ------------------------------------------------------------------ file I/O

function writeAtomic(file, text) {
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, text, { encoding: 'utf8' });
  try {
    fs.renameSync(tmp, file);
  } catch (err) {
    try {
      fs.unlinkSync(tmp);
    } catch {
      /* gone */
    }
    throw err;
  }
}

/**
 * Applies `set` / `remove` to a file. -> { file, client, action, previous, backup }
 * A file that does not exist is created by `set` (no backup); `remove` reports 'absent'.
 */
export function applyToFile({ action, client, file, command, args = [], ownedRoot, stamp }) {
  const format = CLIENTS[client];
  if (!format) throw new ConfigError('BAD_ARGUMENT', `unknown client ${client}`);
  const exists = fs.existsSync(file);
  const text = exists ? fs.readFileSync(file, 'utf8') : '';
  let r;
  if (action === 'set') {
    if (typeof command !== 'string' || !command) throw new ConfigError('BAD_ARGUMENT', '--command is required');
    r = format === 'json' ? setJson(text, file, client, command, args) : setToml(text, file, command, args);
  } else if (action === 'remove') {
    if (!exists) return { file, client, action: 'absent', previous: null, backup: null };
    r = format === 'json' ? removeJson(text, file, ownedRoot) : removeToml(text, file, ownedRoot);
  } else {
    throw new ConfigError('BAD_ARGUMENT', `unknown action ${action}`);
  }
  let backup = null;
  if (r.action === 'added' || r.action === 'updated' || r.action === 'removed') {
    if (exists) {
      const s = stamp || new Date().toISOString().replace(/[-:]/g, '').replace(/\..*$/, '');
      backup = `${file}.bak-${s}`;
      let n = 1;
      while (fs.existsSync(backup)) backup = `${file}.bak-${s}-${n++}`;
      fs.copyFileSync(file, backup);
    } else {
      fs.mkdirSync(path.dirname(file), { recursive: true });
    }
    writeAtomic(file, r.text);
    if (format === 'json') JSON.parse(fs.readFileSync(file, 'utf8')); // read back: still valid JSON
  }
  return { file, client, action: r.action, previous: r.previous, backup };
}

function parseArgs(argv) {
  const o = { args: [] };
  o.action = argv[0];
  for (let i = 1; i < argv.length; i++) {
    const k = argv[i];
    const v = argv[i + 1];
    if (v === undefined) throw new ConfigError('BAD_ARGUMENT', `${k} needs a value`);
    i++;
    if (k === '--client') o.client = v;
    else if (k === '--file') o.file = v;
    else if (k === '--command') o.command = v;
    else if (k === '--arg') o.args.push(v);
    else if (k === '--owned-root') o.ownedRoot = v;
    else if (k === '--stamp') o.stamp = v;
    else throw new ConfigError('BAD_ARGUMENT', `unknown option ${k}`);
  }
  if (!o.file) throw new ConfigError('BAD_ARGUMENT', '--file is required');
  return o;
}

function main() {
  let out;
  try {
    out = { success: true, data: applyToFile(parseArgs(process.argv.slice(2))) };
  } catch (err) {
    out = { success: false, error: { code: err.code && /^[A-Z_]+$/.test(err.code) ? err.code : 'CONFIG_WRITE_FAILED', message: err.message } };
  }
  process.stdout.write(JSON.stringify(out) + '\n');
  process.exitCode = out.success ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();

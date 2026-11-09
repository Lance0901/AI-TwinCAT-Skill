#!/usr/bin/env node
// Registers / unregisters the tcauto MCP server in one MCP client config file (#20). Used by
// Install-TcAuto.ps1 (run with the node.exe it installs); zero dependencies, so it runs from the
// release zip (lib\tcauto-client-config.mjs) as well as from the checkout (scripts\lib\).
//
//   node tcauto-client-config.mjs set    --client <claude-code|claude-desktop|codex> --file <path> --command <exe> --arg <a> [--arg <b> ...] [--stamp <s>]
//   node tcauto-client-config.mjs remove --client <...> --file <path> --owned-root <install root> [--force] [--stamp <s>]
//
// Only the keys the installer owns in the tcauto entry change; every other server, key and table -
// and every other key / sub-table the user put under tcauto (env, default_tools_approval_mode, ...) -
// is kept with its value and position (#204), except env TCAUTO_RUNTIME_ROOT, which is removed: the
// launcher would take its install root from it instead of its own folder, so the client would run
// another runtime than the one the installer verifies. A kept cwd (or Codex enabled = false) is
// reported as a warning, its value is not changed. The result lists keptKeys / removedKeys / warnings.
//   claude-code     ~/.claude.json, top-level mcpServers.tcauto: type = 'stdio', command, args set;
//                   env = {} only when there is none (user scope; projects[*].mcpServers not touched)
//   claude-desktop  claude_desktop_config.json, mcpServers.tcauto: command, args set; which file(s) -
//                   %LOCALAPPDATA%\Claude-Data\claude_*\ (MSIX) and/or %APPDATA%\Claude\ (standard) -
//                   Install-TcAuto.ps1 decides (#165); this helper changes the one --file it gets
//   codex           ~/.codex/config.toml, table [mcp_servers.tcauto]: a command / args statement whose
//                   value differs is rewritten as a whole (its end-of-line comment goes with it);
//                   `remove` drops the table with all its sub-tables. [[mcp_servers.tcauto]] (array of
//                   tables) or a tcauto written as a key is refused (CONFIG_UNSUPPORTED)
// Before a file is changed it is copied to <file>.bak-<stamp>. JSON is written as UTF-8 without BOM,
// with the indent and line ending of the original. TOML lines that are not changed keep their own
// line ending; new or rewritten lines get the one most lines of the file use. The new file is written to a temp file next to
// it and renamed over it. `remove` removes the entry when its command is below --owned-root. An entry
// whose command is elsewhere but one of whose args is below --owned-root (e.g. a developer
// registration "node <root>\launcher\tcauto-launcher.mjs") uses this install too: it is left and
// reported as 'shared' (removed with --force, the caller then removes the files). Any other entry
// (e.g. a developer checkout) is left and reported as 'foreign'.
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

/**
 * The keys of the tcauto entry the installer owns (#204): they are set on every run. Every other key
 * of an existing entry (env, a setting the user added) keeps its value and position; the rest of
 * entryFor() (claude-code: env = {}) is only a default for an entry that does not have the key yet.
 */
const OWNED_KEYS = Object.freeze({ 'claude-code': ['type', 'command', 'args'], 'claude-desktop': ['command', 'args'] });

/** env variable that is never kept: it would make the launcher use another install root */
export const DROPPED_ENV = 'TCAUTO_RUNTIME_ROOT';

/** warning for a kept key that changes how tcauto starts or whether it runs */
function startWarning(file, key, value) {
  return `${file}: tcauto has ${key} = ${value}; this key affects how tcauto starts or whether it is enabled. It was left as it is`;
}

/**
 * previous entry + the owned keys of entryFor(); a previous that is not an object is replaced.
 * -> { entry, keptKeys, removedKeys, warnings }
 */
export function mergeEntry(client, previous, command, args, file = 'config') {
  const entry = entryFor(client, command, args);
  const info = { keptKeys: [], removedKeys: [], warnings: [] };
  if (!isPlainObject(previous)) return { entry, ...info };
  const owned = OWNED_KEYS[client] ?? [];
  const next = { ...previous };
  for (const [k, v] of Object.entries(entry)) {
    if (owned.includes(k) || !(k in next)) next[k] = v;
  }
  if (isPlainObject(next.env) && Object.prototype.hasOwnProperty.call(next.env, DROPPED_ENV)) {
    const { [DROPPED_ENV]: _dropped, ...rest } = next.env;
    next.env = rest;
    info.removedKeys.push(`env.${DROPPED_ENV}`);
  }
  info.keptKeys = Object.keys(previous).filter((k) => !owned.includes(k));
  if ('cwd' in next) info.warnings.push(startWarning(file, 'cwd', JSON.stringify(next.cwd)));
  return { entry: next, ...info };
}

function sameValue(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

/**
 * The long, real form of a Windows path: 8.3 names (C:\Users\RUNNER~1) expanded, as
 * fs.realpathSync.native gives it for the deepest part that exists; the rest is appended as written.
 * Both sides of a comparison go through it, so a registration written with a short name and an
 * install root given with the long one (or the other way round) compare equal.
 */
export function longPath(p) {
  let cur = path.win32.resolve(p);
  const rest = [];
  for (;;) {
    try {
      return path.win32.join(fs.realpathSync.native(cur), ...rest);
    } catch {
      const parent = path.win32.dirname(cur);
      if (parent === cur) return path.win32.resolve(p);
      rest.unshift(path.win32.basename(cur));
      cur = parent;
    }
  }
}

/** true when a path lies below root (long form, case-insensitive, Windows paths). */
export function isOwned(command, root) {
  if (typeof command !== 'string' || !command || typeof root !== 'string' || !root) return false;
  if (!path.win32.isAbsolute(command)) return false; // 'node' (from PATH) is never below a folder
  const norm = (p) => longPath(p).replace(/[\\/]+$/, '').toLowerCase();
  return norm(command).startsWith(norm(root) + '\\');
}

/** 'owned' (command below root), 'shared' (only an arg below root) or 'foreign' */
export function usageOf(command, args, root) {
  if (isOwned(command, root)) return 'owned';
  if (Array.isArray(args) && args.some((a) => isOwned(a, root))) return 'shared';
  return 'foreign';
}

/** remove decision: -> 'remove' | 'shared' | 'foreign' */
function removeDecision(command, args, root, force) {
  const u = usageOf(command, args, root);
  if (u === 'owned' || (u === 'shared' && force)) return 'remove';
  return u;
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

/** -> { text, action: 'added' | 'updated' | 'unchanged', previous, keptKeys, removedKeys, warnings } */
export function setJson(text, file, client, command, args) {
  const obj = parseJson(text ?? '', file);
  if (obj.mcpServers !== undefined && !isPlainObject(obj.mcpServers)) {
    throw new ConfigError('CONFIG_INVALID', `${file}: mcpServers is not an object; it was not changed`);
  }
  const servers = obj.mcpServers ?? {};
  const previous = servers[SERVER_NAME] ?? null;
  const { entry, ...info } = mergeEntry(client, previous, command, args, file);
  if (previous !== null && sameValue(previous, entry)) return { text, action: 'unchanged', previous, ...info };
  servers[SERVER_NAME] = entry;
  obj.mcpServers = servers;
  return { text: formatJson(obj, text), action: previous === null ? 'added' : 'updated', previous, ...info };
}

/** -> { text, action: 'removed' | 'absent' | 'shared' | 'foreign', previous } */
export function removeJson(text, file, ownedRoot, force = false) {
  const obj = parseJson(text ?? '', file);
  const servers = isPlainObject(obj.mcpServers) ? obj.mcpServers : null;
  const previous = servers?.[SERVER_NAME] ?? null;
  if (previous === null) return { text, action: 'absent', previous };
  const decision = removeDecision(previous?.command, previous?.args, ownedRoot, force);
  if (decision !== 'remove') return { text, action: decision, previous };
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

const isTcauto = (parts) => Array.isArray(parts) && parts.length >= 2 && parts[0] === 'mcp_servers' && parts[1] === SERVER_NAME;
const isTcautoTable = (parts) => isTcauto(parts) && parts.length === 2;
const KEY_RE = /^\s*((?:"(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_-]+)(?:\s*\.\s*(?:"(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_-]+))*)\s*=\s*/;

/** -> { lines: [{ text, term }], eol }: each line with its own line ending; eol = the one most lines use */
function splitLines(src) {
  const parts = src.split(/(\r?\n)/);
  const lines = [];
  for (let i = 0; i < parts.length; i += 2) lines.push({ text: parts[i], term: parts[i + 1] ?? '' });
  const last = lines[lines.length - 1];
  if (last && last.text === '' && last.term === '') lines.pop();
  const crlf = lines.filter((l) => l.term === '\r\n').length;
  const lf = lines.filter((l) => l.term === '\n').length;
  return { lines, eol: crlf > lf ? '\r\n' : '\n' };
}

/** lines -> text; a line without ending gets eol unless it is the last one (lastEol: the last one too) */
function emitLines(lines, eol, lastEol) {
  return lines.map((l, i) => l.text + (l.term || (i < lines.length - 1 || lastEol ? eol : ''))).join('');
}

function joinLines(lines, eol) {
  // drop trailing empty lines, end with a line break
  const out = [...lines];
  while (out.length && out[out.length - 1].text.trim() === '') out.pop();
  return emitLines(out, eol, true);
}

/**
 * Index of the line on which the value that starts at lines[i] (column col) ends: a value that is not
 * an array / inline table / multi-line string ends on its line, the others on the line where they
 * close (strings, '#' comments and nesting are followed). Never closed: the last line.
 */
function valueEnd(lines, i, col) {
  let depth = 0;
  let str = null; // ', ", ''' or """ while inside a string
  for (let l = i; l < lines.length; l++) {
    const line = lines[l].text;
    for (let c = l === i ? col : 0; c < line.length; c++) {
      const ch = line[c];
      if (str) {
        if (str[0] === '"' && ch === '\\') c++;
        else if (line.startsWith(str, c)) {
          c += str.length - 1;
          str = null;
        }
        continue;
      }
      if (ch === '#') break;
      if (ch === "'" || ch === '"') {
        str = line.startsWith(ch.repeat(3), c) ? ch.repeat(3) : ch;
        c += str.length - 1;
      } else if (ch === '[' || ch === '{') depth++;
      else if ((ch === ']' || ch === '}') && --depth <= 0) depth = 0;
    }
    if (str && str.length === 1) str = null; // a one-line string does not go on
    if (depth <= 0 && !str) return l;
  }
  return lines.length - 1;
}

/**
 * The statements of a TOML text, in order: { kind: 'table' | 'array' | 'kv' | 'other', first, last,
 * table (key parts of the table it is in; for a header its own), key (kv: key parts), indent, col }.
 * A key/value covers all lines of its value, so a line inside a multi-line string or array is never
 * read as a header or a key.
 */
function scanToml(lines, file) {
  const out = [];
  let table = [];
  for (let i = 0; i < lines.length; i++) {
    const text = lines[i].text;
    const arr = ARRAY_HEADER_RE.exec(text);
    const hdr = arr ? null : HEADER_RE.exec(text);
    if (arr || hdr) {
      const parts = keyParts((arr ?? hdr)[1]);
      if (parts === null) throw new ConfigError('CONFIG_UNSUPPORTED', `${file}: cannot read the table header ${text.trim()}; it was not changed`);
      table = parts;
      out.push({ kind: arr ? 'array' : 'table', first: i, last: i, table });
      continue;
    }
    const km = KEY_RE.exec(text);
    const key = km ? keyParts(km[1]) : null;
    if (key) {
      const last = valueEnd(lines, i, km[0].length);
      out.push({ kind: 'kv', first: i, last, table, key, indent: /^\s*/.exec(text)[0], col: km[0].length });
      i = last;
      continue;
    }
    out.push({ kind: 'other', first: i, last: i, table });
  }
  return out;
}

/**
 * Statements + the lines of the tcauto sections ([mcp_servers.tcauto] and [mcp_servers.tcauto.*],
 * header to the next header) and of the rest. A tcauto defined any other way (inline table in
 * [mcp_servers], dotted key, [[mcp_servers.tcauto]] array of tables) is refused rather than guessed at.
 */
function splitToml(lines, file) {
  const stmts = scanToml(lines, file);
  const keep = [];
  const removed = [];
  for (const s of stmts) {
    if (s.kind === 'array' && isTcauto(s.table)) {
      throw new ConfigError('CONFIG_UNSUPPORTED', `${file}: ${lines[s.first].text.trim()} is an array of tables; tcauto must be one [mcp_servers.${SERVER_NAME}] table. Edit it by hand. The file was not changed`);
    }
    if (s.kind === 'kv' && !isTcauto(s.table) && isTcauto([...s.table, ...s.key])) {
      throw new ConfigError('CONFIG_UNSUPPORTED', `${file}: ${SERVER_NAME} is defined as a key (${lines[s.first].text.trim()}), not as a [mcp_servers.${SERVER_NAME}] table; edit it by hand. The file was not changed`);
    }
    (isTcauto(s.table) ? removed : keep).push(...lines.slice(s.first, s.last + 1));
  }
  return { stmts, keep, removed };
}

/** the text of a key/value statement after `key =` */
function valueText(lines, s) {
  return lines
    .slice(s.first, s.last + 1)
    .map((l) => l.text)
    .join('\n')
    .slice(s.col);
}

function unescapeBasic(raw) {
  try {
    return JSON.parse(`"${raw.replace(/\r?\n/g, '\\n')}"`);
  } catch {
    return raw;
  }
}

/** the string values in a TOML value text, in order ('#' comments skipped) */
function tomlStrings(text) {
  const out = [];
  for (let c = 0; c < text.length; c++) {
    const ch = text[c];
    if (ch === '#') {
      const nl = text.indexOf('\n', c);
      if (nl < 0) break;
      c = nl;
      continue;
    }
    if (ch !== "'" && ch !== '"') continue;
    const q = text.startsWith(ch.repeat(3), c) ? ch.repeat(3) : ch;
    let end = c + q.length;
    let raw = '';
    while (end < text.length && !text.startsWith(q, end)) {
      if (ch === '"' && text[end] === '\\') {
        raw += text.slice(end, end + 2);
        end += 2;
      } else raw += text[end++];
    }
    if (q.length === 3) raw = raw.replace(/^\r?\n/, ''); // a line break right after the opening quotes is not part of it
    out.push(ch === "'" ? raw : unescapeBasic(raw));
    c = end + q.length - 1;
  }
  return out;
}

/** command of a kv statement: its string value, or null */
function commandValue(lines, s) {
  const v = valueText(lines, s).trimStart();
  return v.startsWith("'") || v.startsWith('"') ? (tomlStrings(v)[0] ?? null) : null;
}

/** args of a kv statement: the strings of its array, or null when it is no array */
function argsValue(lines, s) {
  const v = valueText(lines, s).trimStart();
  return v.startsWith('[') ? tomlStrings(v) : null;
}

/** top-level entries of an inline table value ('{ a = 1, b = "x" }' -> ['a = 1', 'b = "x"']), or null */
function inlineEntries(value) {
  const v = value.trim();
  if (!v.startsWith('{')) return null;
  const entries = [];
  let depth = 0;
  let str = null;
  let cur = '';
  for (let c = 0; c < v.length; c++) {
    const ch = v[c];
    if (str) {
      cur += ch;
      if (str[0] === '"' && ch === '\\') cur += v[++c] ?? '';
      else if (v.startsWith(str, c)) {
        cur += str.slice(1);
        c += str.length - 1;
        str = null;
      }
      continue;
    }
    if (ch === "'" || ch === '"') {
      str = v.startsWith(ch.repeat(3), c) ? ch.repeat(3) : ch;
      cur += str;
      c += str.length - 1;
      continue;
    }
    if (ch === '{' || ch === '[') {
      depth++;
      if (depth === 1) continue;
    } else if (ch === '}' || ch === ']') {
      depth--;
      if (depth === 0) {
        if (cur.trim()) entries.push(cur.trim());
        return v.slice(c + 1).trim() === '' || v.slice(c + 1).trim().startsWith('#') ? entries : null;
      }
    } else if (ch === ',' && depth === 1) {
      entries.push(cur.trim());
      cur = '';
      continue;
    }
    cur += ch;
  }
  return null;
}

/** the kv statements of [mcp_servers.tcauto] itself with key command / args */
function ownedStatements(stmts, name) {
  return stmts.filter((s) => s.kind === 'kv' && isTcautoTable(s.table) && s.key.length === 1 && s.key[0] === name);
}

/** key below tcauto ('env.X', 'tools.ReadVariable') */
const relKey = (s) => (s.kind === 'kv' ? [...s.table, ...s.key] : s.table).slice(2);

/** written text -> CONFIG_UNSUPPORTED unless tcauto has exactly one command / args with the wanted values */
function checkToml(text, file, command, args) {
  const { lines } = splitLines(text);
  const { stmts } = splitToml(lines, file);
  const cmd = ownedStatements(stmts, 'command');
  const arg = ownedStatements(stmts, 'args');
  const headers = stmts.filter((s) => s.kind === 'table' && isTcautoTable(s.table)).length;
  const dropped = stmts.some((s) => s.kind === 'kv' && isTcauto(s.table) && relKey(s).join('.') === `env.${DROPPED_ENV}`);
  const problem =
    headers !== 1
      ? `${headers} [mcp_servers.${SERVER_NAME}] headers`
      : cmd.length !== 1 || arg.length !== 1
        ? `${cmd.length} command and ${arg.length} args keys`
        : commandValue(lines, cmd[0]) !== command || !sameValue(argsValue(lines, arg[0]), args)
          ? 'command / args not readable back'
          : dropped
            ? `env ${DROPPED_ENV} still there`
            : null;
  if (problem) {
    throw new ConfigError('CONFIG_UNSUPPORTED', `${file}: [mcp_servers.${SERVER_NAME}] could not be updated safely (${problem} after the change); edit it by hand. The file was not changed`);
  }
}

/**
 * -> { text, action, previous, keptKeys, removedKeys, warnings } (previous: the tcauto sections before
 * the change, or null). Only `command` and `args` of [mcp_servers.tcauto] are set (#204): a statement
 * whose value differs is rewritten as a whole, end-of-line comment included; one with the wanted value
 * is left as written; a missing one is added next to the other one (or below the header). env
 * TCAUTO_RUNTIME_ROOT (in [mcp_servers.tcauto.env], env.X = or an inline env = {...}) is removed.
 * Every other key, comment and sub-table of tcauto keeps its text and position, the rest of the file
 * is not touched, and unchanged lines keep their own line ending. A file without the table gets it
 * appended. The result is read back before it is returned (checkToml).
 */
export function setToml(text, file, command, args) {
  const src = (text ?? '').replace(/^\uFEFF/, '');
  const { lines, eol } = splitLines(src);
  const { stmts, keep, removed } = splitToml(lines, file);
  const info = { keptKeys: [], removedKeys: [], warnings: [] };
  const section = tomlSection(command, args, eol);
  if (!removed.length) {
    const rest = joinLines(keep, eol);
    const out = (rest ? rest + eol : '') + section;
    checkToml(out, file, command, args);
    return { text: out, action: 'added', previous: null, ...info };
  }
  const previous = joinLines(removed, eol);
  const nl = (t) => ({ text: t, term: eol });
  const want = { command: `command = ${tomlString(command)}`, args: `args = [${args.map(tomlString).join(', ')}]` };
  const found = { command: ownedStatements(stmts, 'command')[0], args: ownedStatements(stmts, 'args')[0] };
  const keepAsIs = {
    command: found.command !== undefined && commandValue(lines, found.command) === command,
    args: found.args !== undefined && sameValue(argsValue(lines, found.args), args)
  };
  const hasHeader = stmts.some((s) => s.kind === 'table' && isTcautoTable(s.table));
  const kept = new Set();
  const res = [];
  for (const s of stmts) {
    const own = lines.slice(s.first, s.last + 1);
    const inTcauto = isTcauto(s.table);
    const rel = inTcauto ? relKey(s) : [];
    if (!inTcauto) {
      res.push(...own);
      continue;
    }
    if (s.kind === 'table') {
      res.push(...own);
      if (rel.length) kept.add(rel.join('.'));
      else if (!found.command && !found.args) res.push(nl(want.command), nl(want.args));
      continue;
    }
    if (s.kind !== 'kv') {
      res.push(...own);
      continue;
    }
    const key = rel.join('.');
    if (s === found.command || s === found.args) {
      const name = s === found.command ? 'command' : 'args';
      if (name === 'args' && !found.command) res.push(nl(s.indent + want.command));
      res.push(...(keepAsIs[name] ? own : [{ text: s.indent + want[name], term: lines[s.last].term }]));
      if (name === 'command' && !found.args) res.push(nl(s.indent + want.args));
      continue;
    }
    if (key === `env.${DROPPED_ENV}`) {
      info.removedKeys.push(key);
      continue;
    }
    const entries = key === 'env' ? inlineEntries(valueText(lines, s)) : null;
    if (entries) {
      const rest = entries.filter((e) => {
        const km = KEY_RE.exec(e);
        const k = km ? keyParts(km[1]) : null;
        return !(k && k.length === 1 && k[0] === DROPPED_ENV);
      });
      if (rest.length !== entries.length) {
        info.removedKeys.push(`env.${DROPPED_ENV}`);
        res.push({ text: `${s.indent}env = { ${rest.join(', ')} }`.replace('{  }', '{}'), term: lines[s.last].term });
        if (s.table.length === 2) kept.add('env');
        continue;
      }
    }
    res.push(...own);
    if (s.table.length === 2) kept.add(key);
    if (key === 'cwd') info.warnings.push(startWarning(file, 'cwd', valueText(lines, s).trim()));
    if (key === 'enabled' && /^false\b/.test(valueText(lines, s).trim())) info.warnings.push(startWarning(file, 'enabled', 'false'));
  }
  info.keptKeys = [...kept];
  let out = emitLines(res, eol, false);
  if (!hasHeader) out = (joinLines(res, eol) ? joinLines(res, eol) + eol : '') + section; // only sub-tables: the table itself is appended (valid TOML)
  checkToml(out, file, command, args);
  if (out === src) return { text, action: 'unchanged', previous, ...info };
  return { text: out, action: 'updated', previous, ...info };
}

/** -> { text, action: 'removed' | 'absent' | 'shared' | 'foreign', previous } */
export function removeToml(text, file, ownedRoot, force = false) {
  const src = (text ?? '').replace(/^\uFEFF/, '');
  const { lines, eol } = splitLines(src);
  const { stmts, keep, removed } = splitToml(lines, file);
  if (!removed.length) return { text, action: 'absent', previous: null };
  const previous = joinLines(removed, eol);
  const cmd = ownedStatements(stmts, 'command')[0];
  const arg = ownedStatements(stmts, 'args')[0];
  const decision = removeDecision(cmd ? commandValue(lines, cmd) : null, arg ? (argsValue(lines, arg) ?? []) : [], ownedRoot, force);
  if (decision !== 'remove') return { text, action: decision, previous };
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
 * Applies `set` / `remove` to a file. -> { file, client, action, previous, backup, keptKeys, removedKeys, warnings }
 * A file that does not exist is created by `set` (no backup); `remove` reports 'absent'.
 */
export function applyToFile({ action, client, file, command, args = [], ownedRoot, stamp, force = false }) {
  const format = CLIENTS[client];
  if (!format) throw new ConfigError('BAD_ARGUMENT', `unknown client ${client}`);
  const exists = fs.existsSync(file);
  const text = exists ? fs.readFileSync(file, 'utf8') : '';
  let r;
  if (action === 'set') {
    if (typeof command !== 'string' || !command) throw new ConfigError('BAD_ARGUMENT', '--command is required');
    r = format === 'json' ? setJson(text, file, client, command, args) : setToml(text, file, command, args);
  } else if (action === 'remove') {
    if (!exists) return { file, client, action: 'absent', previous: null, backup: null, keptKeys: [], removedKeys: [], warnings: [] };
    r = format === 'json' ? removeJson(text, file, ownedRoot, force) : removeToml(text, file, ownedRoot, force);
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
  return { file, client, action: r.action, previous: r.previous, backup, keptKeys: r.keptKeys ?? [], removedKeys: r.removedKeys ?? [], warnings: r.warnings ?? [] };
}

function parseArgs(argv) {
  const o = { args: [] };
  o.action = argv[0];
  for (let i = 1; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--force') {
      o.force = true;
      continue;
    }
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

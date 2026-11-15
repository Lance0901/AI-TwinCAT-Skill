// #310: GetGuide(topic). The flow card (instructions.md) is the index; the topic files below
// guide/ hold the how-to for one task each (when to do what, what to do on a failure). Both ship
// inside the runtime folder (Install-TcAutoRuntime.ps1 / Build-TcAutoRelease.ps1 copy mcp-server\
// without test\), so every client - also one that ignores the MCP `instructions` (Codex) - gets the
// same single source through a tool call. Read-only: no IDE, no ADS, no bridge.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadInstructions } from './instructions.js';
const BOM = new RegExp('^' + String.fromCharCode(0xfeff));

export const GUIDE_DIR = 'guide';
export const START_TOPIC = 'start';
const TOPIC_RE = /^[a-z][a-z0-9-]{0,40}$/;

const MCP_SERVER_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

function readText(file) {
  return fs.readFileSync(file, 'utf8').replace(BOM, '').replace(/\r\n/g, '\n').trim();
}

/**
 * Topic files of a runtime: guide/<topic>.md. The first line is "# <topic>: <one sentence>".
 * @param {string} [dir] mcp-server folder (default: the one this file belongs to)
 * @returns {{ name: string, summary: string, file: string }[]} sorted by name
 */
export function listTopics(dir = MCP_SERVER_DIR) {
  const folder = path.join(dir, GUIDE_DIR);
  let names;
  try {
    names = fs.readdirSync(folder);
  } catch {
    return [];
  }
  const topics = [];
  for (const f of names) {
    if (!f.endsWith('.md')) continue;
    const name = f.slice(0, -3);
    if (!TOPIC_RE.test(name) || name === START_TOPIC) continue;
    const file = path.join(folder, f);
    let summary = '';
    try {
      const first = readText(file).split('\n', 1)[0];
      const m = /^#\s+[a-z0-9-]+\s*:\s*(.+)$/.exec(first);
      summary = m ? m[1].trim() : first.replace(/^#\s*/, '').trim();
    } catch {
      continue;
    }
    topics.push({ name, summary, file });
  }
  return topics.sort((a, b) => a.name.localeCompare(b.name));
}

function errorResult(code, message, hint, data) {
  const error = { code, message };
  if (hint) error.hint = hint;
  return data ? { success: false, error, data } : { success: false, error };
}

/**
 * @param {string|undefined} topic
 * @param {string} [dir] mcp-server folder
 * @returns {{success: boolean, data?: object, error?: object}}
 */
export function getGuide(topic, dir = MCP_SERVER_DIR) {
  const topics = listTopics(dir);
  const index = topics.map(({ name, summary }) => ({ name, summary }));
  if (topics.length === 0) {
    return errorResult('GUIDE_UNAVAILABLE', `No topic files in ${path.join(dir, GUIDE_DIR)}: the runtime is incomplete.`, 'Reinstall the TcAuto runtime (Install-TcAuto.ps1, or scripts/Install-TcAutoRuntime.ps1 in a checkout), then ReloadRuntime.', { topics: [] });
  }
  const wanted = typeof topic === 'string' && topic.trim() !== '' ? topic.trim().toLowerCase() : START_TOPIC;
  if (wanted === START_TOPIC) {
    const card = loadInstructions(dir);
    if (!card.text) {
      return errorResult('GUIDE_UNAVAILABLE', `The flow card ${card.path} could not be read: ${card.error}.`, 'Reinstall the TcAuto runtime (Install-TcAuto.ps1, or scripts/Install-TcAutoRuntime.ps1 in a checkout), then ReloadRuntime.', { topics: index });
    }
    return { success: true, data: { topic: START_TOPIC, text: card.text, topics: index } };
  }
  const hit = topics.find((t) => t.name === wanted);
  if (!hit) {
    const known = [START_TOPIC, ...index.map((t) => t.name)];
    return errorResult(
      'GUIDE_TOPIC_UNKNOWN',
      `Unknown guide topic '${wanted}'. Available: ${known.join(', ')}.`,
      `Call GetGuide with one of: ${known.join(', ')}.`,
      { topics: index }
    );
  }
  try {
    return { success: true, data: { topic: hit.name, summary: hit.summary, text: readText(hit.file) } };
  } catch (err) {
    return errorResult('GUIDE_UNAVAILABLE', `Topic file ${hit.file} could not be read: ${err?.message ?? String(err)}.`, 'Reinstall the TcAuto runtime, then ReloadRuntime.', { topics: index });
  }
}

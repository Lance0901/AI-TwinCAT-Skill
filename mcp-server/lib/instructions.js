// #307: the TcAuto flow card (mcp-server/instructions.md) sent as the MCP `instructions` of the
// initialize result. One page for every client: golden rules, the tool order per task, when to
// ask the user, what to do on a failure. A missing / unreadable file never stops the server: it
// then starts without instructions and logs why on stderr.
import fs from 'node:fs';
import path from 'node:path';

export const INSTRUCTIONS_FILE = 'instructions.md';

/**
 * @param {string} dir folder that holds instructions.md (the mcp-server folder of this runtime)
 * @returns {{ text: string|undefined, path: string, error: string|null }}
 */
export function loadInstructions(dir) {
  const file = path.join(dir, INSTRUCTIONS_FILE);
  try {
    const text = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').trim();
    if (text === '') return { text: undefined, path: file, error: 'file is empty' };
    return { text, path: file, error: null };
  } catch (err) {
    return { text: undefined, path: file, error: err?.message ?? String(err) };
  }
}

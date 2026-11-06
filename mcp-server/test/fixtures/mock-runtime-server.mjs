// Mock of a runtime's mcp-server/index.js for test/launcher.test.js (#162). Test use only.
// The test copies this file to <install root>\runtime\<version>\mcp-server\index.js. No SDK:
// newline-delimited JSON-RPC by hand.
//
// Reads <runtime dir>\tcauto-source.json (commit) and <runtime dir>\behavior.json:
//   { "retire": "ok" | "blocked" | "unsupported" | "slow", "retireDelayMs": n, "initFail": true }
// Appends every message it receives to <runtime dir>\received.jsonl.
// Tools: Echo (data: commit, args, ownerId, launcherPid, ppid, pid), Slow (answers after
// arguments.ms), Crash (exits with code 3 without answering).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const runtimeDir = path.resolve(here, '..');
const readJson = (f, d) => {
  try {
    return JSON.parse(fs.readFileSync(f, 'utf8'));
  } catch {
    return d;
  }
};
const stamp = readJson(path.join(runtimeDir, 'tcauto-source.json'), {});
const behavior = readJson(path.join(runtimeDir, 'behavior.json'), {});
const received = path.join(runtimeDir, 'received.jsonl');

const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');
const ok = (id, result) => send({ jsonrpc: '2.0', id, result });
const tool = (body) => ({ content: [{ type: 'text', text: JSON.stringify(body) }], isError: body.success !== true, structuredContent: body });

const TOOLS = ['Echo', 'Slow', 'Crash'].map((name) => ({ name, description: `mock ${name}`, inputSchema: { type: 'object', properties: {} } }));

function handle(msg) {
  fs.appendFileSync(received, JSON.stringify(msg) + '\n');
  if (msg.method === 'initialize') {
    if (behavior.initFail) {
      send({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: 'mock init failure' } });
      return;
    }
    ok(msg.id, { protocolVersion: msg.params?.protocolVersion ?? '2025-06-18', capabilities: { tools: {}, logging: {} }, serverInfo: { name: 'mock-runtime', version: stamp.commit ?? '?' } });
    return;
  }
  if (msg.method === 'tools/list') {
    ok(msg.id, { tools: TOOLS });
    return;
  }
  if (msg.method === 'tcauto/retire') {
    const answer = () => {
      if (behavior.retire === 'unsupported') send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'Method not found' } });
      else if (behavior.retire === 'blocked') ok(msg.id, { success: false, error: { code: 'RELOAD_LIFECYCLE_BLOCKED', message: 'mock block', hint: 'report it' }, data: { lifecycleBlocks: [{ amsNetId: 'mock' }], notRun: true } });
      else ok(msg.id, { success: true, data: { retired: true, ideWasConnected: true, adsWasConnected: false, buildRequiredPersisted: [] } });
    };
    if (behavior.retireDelayMs) setTimeout(answer, behavior.retireDelayMs);
    else answer();
    return;
  }
  if (msg.method === 'tools/call') {
    const name = msg.params?.name;
    const args = msg.params?.arguments ?? {};
    if (name === 'Crash') process.exit(3);
    if (name === 'Slow') {
      setTimeout(() => ok(msg.id, tool({ success: true, data: { slept: args.ms } })), Number(args.ms) || 500);
      return;
    }
    if (name === 'Echo') {
      ok(
        msg.id,
        tool({
          success: true,
          data: { commit: stamp.commit ?? null, args, ownerId: process.env.TCAUTO_LAUNCHER_OWNER_ID ?? null, launcherPid: process.env.TCAUTO_LAUNCHER_PID ?? null, ppid: process.ppid, pid: process.pid }
        })
      );
      return;
    }
    ok(msg.id, tool({ success: false, error: { code: 'UNKNOWN_TOOL', message: name } }));
    return;
  }
  if (msg.id !== undefined && msg.method) send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'Method not found' } });
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (line) handle(JSON.parse(line));
  }
});
process.stdin.on('end', () => process.exit(0));

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { isIdeProcessAlive, parseTasklistImageName } from '../lib/ide-process.js';

const XAE_ROW = '"TcXaeShell.exe","18324","Console","1","512,000 K"\r\n';
const DEVENV_ROW = '"devenv.exe","9001","Console","1","300,000 K"\r\n';
const OTHER_ROW = '"powershell.exe","4242","Console","1","78,084 K"\r\n';
const NO_MATCH = 'INFO: No tasks are running which match the specified criteria.\r\n';

describe('parseTasklistImageName', () => {
  test('reads the image name of the CSV row and ignores the no-match line (any locale)', () => {
    assert.equal(parseTasklistImageName(XAE_ROW), 'TcXaeShell.exe');
    assert.equal(parseTasklistImageName(DEVENV_ROW), 'devenv.exe');
    assert.equal(parseTasklistImageName(NO_MATCH), null);
    assert.equal(parseTasklistImageName('找不到符合的工作。\r\n'), null);
    assert.equal(parseTasklistImageName(''), null);
    assert.equal(parseTasklistImageName(null), null);
  });
});

describe('isIdeProcessAlive', () => {
  const env = {}; // no TWINCAT_MCP_SKIP_PID_CHECK
  const stub = (output) => async () => output;

  test('true only for a live TcXaeShell.exe / devenv.exe', async () => {
    assert.equal(await isIdeProcessAlive(18324, { env, platform: 'win32', tasklist: stub(XAE_ROW) }), true);
    assert.equal(await isIdeProcessAlive(9001, { env, platform: 'win32', tasklist: stub(DEVENV_ROW) }), true);
    assert.equal(await isIdeProcessAlive(4242, { env, platform: 'win32', tasklist: stub(OTHER_ROW) }), false, 'pid recycled by another image');
    assert.equal(await isIdeProcessAlive(4242, { env, platform: 'win32', tasklist: stub(NO_MATCH) }), false, 'pid not running');
    assert.equal(await isIdeProcessAlive(4242, { env, platform: 'win32', tasklist: stub(null) }), false, 'tasklist failed -> generic hint');
  });

  test('tasklist is queried with the pid filter', async () => {
    const calls = [];
    await isIdeProcessAlive(123, { env, platform: 'win32', tasklist: async (pid) => (calls.push(pid), XAE_ROW) });
    assert.deepEqual(calls, [123]);
  });

  test('invalid pid, non-Windows host -> false without querying', async () => {
    const never = async () => assert.fail('tasklist must not run');
    assert.equal(await isIdeProcessAlive(0, { env, platform: 'win32', tasklist: never }), false);
    assert.equal(await isIdeProcessAlive(-1, { env, platform: 'win32', tasklist: never }), false);
    assert.equal(await isIdeProcessAlive(1.5, { env, platform: 'win32', tasklist: never }), false);
    assert.equal(await isIdeProcessAlive(null, { env, platform: 'win32', tasklist: never }), false);
    assert.equal(await isIdeProcessAlive(4242, { env, platform: 'linux', tasklist: never }), false);
  });

  test('TWINCAT_MCP_SKIP_PID_CHECK=1 skips the check (mock IDE pids in tests)', async () => {
    const never = async () => assert.fail('tasklist must not run');
    assert.equal(await isIdeProcessAlive(4242, { env: { TWINCAT_MCP_SKIP_PID_CHECK: '1' }, platform: 'win32', tasklist: never }), true);
    assert.equal(await isIdeProcessAlive(4242, { env: { TWINCAT_MCP_SKIP_PID_CHECK: '0' }, platform: 'win32', tasklist: stub(NO_MATCH) }), false);
  });

  test('real tasklist: the current node process is alive but not an IDE', { skip: process.platform !== 'win32' }, async () => {
    assert.equal(await isIdeProcessAlive(process.pid, { env }), false);
  });
});

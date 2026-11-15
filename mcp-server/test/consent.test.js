// #258: consent gate (lib/consent.js) - unit tests of the pure logic, then end to end: real MCP
// client over stdio (with / without the elicitation capability) -> index.js -> mock bridge.
// Every refusal asserts that the cmdlet never reached the bridge (MOCK_BRIDGE_CALL_LOG).
// The client answers are stand-ins for the measured behaviour (#258 owner test, see lib/consent.js header):
// claude -p cancels, codex exec declines, codex full-access accepts a form without fields.
import { test, describe, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { ElicitRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import {
  consentKind,
  sanitizeValue,
  buildConsentRequest,
  isApproved,
  askUser,
  ConsentMemory,
  consentErrorResult,
  consentBlockedBy,
  supportsFormElicitation,
  ELICIT_TIMEOUT_MS
} from '../lib/consent.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', 'index.js');
const FIXTURE = path.join(__dirname, 'fixtures', 'tools.fixture.consent.json');
const MOCK = path.join(__dirname, 'fixtures', 'mock-bridge.js');
const UMRT = '199.5.42.250.1.1'; // local-umrt in the mock's targetkind table

describe('consent.js (pure logic)', () => {
  test('consentKind: which calls are gated', () => {
    assert.equal(consentKind('InstallPackage', { PackageId: 'x', Version: '1' }), null, 'a plan is not gated');
    assert.equal(consentKind('InstallPackage', { Approved: true }).kind, 'install');
    for (const t of ['AddAdsRoute', 'InstallLibrary', 'UninstallLibrary']) {
      assert.equal(consentKind(t, {}), null, `${t} default DryRun`);
      assert.equal(consentKind(t, { DryRun: true }), null);
      assert.equal(consentKind(t, { DryRun: false }).kind, 'always');
    }
    assert.equal(consentKind('ResetSolution', {}), null);
    assert.equal(consentKind('ResetSolution', { Force: true }).kind, 'always');
    assert.equal(consentKind('ConnectIde', { SolutionPath: 'a.sln' }), null);
    assert.equal(consentKind('ConnectIde', { ProcessId: 12 }).kind, 'ide');
    for (const t of ['EnableConfig', 'RunTestCycle', 'RunTest', 'WriteVariable', 'SetPlcState', 'SetSystemState', 'PlcLogin', 'SendPlcProgram']) {
      assert.equal(consentKind(t, {}).kind, 'runtime', t);
    }
    assert.equal(consentKind('SetTcComParameter', { Online: true }), null, 'dry run by default');
    assert.equal(consentKind('SetTcComParameter', { DryRun: false }), null, 'project only');
    assert.equal(consentKind('SetTcComParameter', { Online: true, DryRun: false }).kind, 'runtime');
    for (const t of ['ClearLifecycleBlock', 'DeleteChild', 'PlcLogout', 'ReadVariable', 'WatchVariable', 'GenerateBootProject', 'IoScan', 'SetTarget', 'BuildProject']) {
      assert.equal(consentKind(t, { Apply: true, DryRun: false }), null, t);
    }
  });

  test('sanitizeValue: no control characters, cut at 60', () => {
    const v = sanitizeValue('a\nb\r\nc\u0007d\u202Ee' + 'x'.repeat(500));
    assert.doesNotMatch(v, /[\n\r\u0007\u202E]/);
    assert.ok(v.startsWith('a b c d e'));
    assert.equal(v, 'a b c d e' + 'x'.repeat(51) + '...');
    assert.equal(sanitizeValue({ a: 1 }), '{"a":1}');
    assert.equal(sanitizeValue(true), 'true');
  });

  test('buildConsentRequest: required enum field, fixed text, parameters labelled', () => {
    const r = buildConsentRequest({ tool: 'WriteVariable', gate: consentKind('WriteVariable', {}), params: { Path: 'MAIN.x', Value: 5 }, amsNetId: '5.1.2.3.1.1', targetKind: 'remote' });
    assert.deepEqual(r.requestedSchema.required, ['decision']);
    assert.deepEqual(r.requestedSchema.properties.decision.enum, ['approve', 'reject']);
    assert.match(r.message, /^TcAuto asks you before it runs WriteVariable\./);
    assert.match(r.message, /Target AmsNetId: 5\.1\.2\.3\.1\.1/);
    assert.match(r.message, /Target kind: remote/);
    assert.match(r.message, /Parameter Path: MAIN\.x/);
    assert.match(r.message, /Parameter Value: 5/);
  });

  test('isApproved: only accept + decision approve', () => {
    assert.equal(isApproved({ action: 'accept', content: { decision: 'approve' } }), true);
    assert.equal(isApproved({ action: 'accept', content: { decision: 'reject' } }), false);
    assert.equal(isApproved({ action: 'accept', content: {} }), false);
    assert.equal(isApproved({ action: 'accept' }), false);
    assert.equal(isApproved({ action: 'decline' }), false);
    assert.equal(isApproved({ action: 'cancel' }), false);
    assert.equal(isApproved(null), false);
  });

  test('supportsFormElicitation: {} and {form} yes, url only / none no', () => {
    assert.equal(supportsFormElicitation({ elicitation: {} }), true);
    assert.equal(supportsFormElicitation({ elicitation: { form: {} } }), true);
    assert.equal(supportsFormElicitation({ elicitation: { url: {} } }), false);
    assert.equal(supportsFormElicitation({}), false);
    assert.equal(supportsFormElicitation(undefined), false);
  });

  test('askUser: unsupported / approved / declined / failed; timeout 600000', async () => {
    const seen = [];
    const mk = (caps, answer) => ({ getClientCapabilities: () => caps, elicit: async (p, o) => (seen.push(o), answer(p)) });
    assert.equal(await askUser(mk(null, () => ({})), {}), 'unsupported');
    assert.equal(await askUser(mk({ elicitation: {} }, () => ({ action: 'accept', content: { decision: 'approve' } })), {}), 'approved');
    assert.equal(seen[0].timeout, ELICIT_TIMEOUT_MS);
    assert.equal(ELICIT_TIMEOUT_MS, 600000);
    assert.equal(await askUser(mk({ elicitation: {} }, () => ({ action: 'cancel' })), {}), 'declined');
    assert.equal(
      await askUser(mk({ elicitation: {} }, () => { throw new Error('timeout'); }), {}),
      'failed'
    );
  });

  test('ConsentMemory: plans one use and bound to PackageId / Version; targets case-insensitive', () => {
    const m = new ConsentMemory();
    m.rememberPlan({ success: true, data: { executed: false, planToken: 't1', packageId: 'P', version: '1', command: 'tcpkg install P=1 -y' } });
    m.rememberPlan({ success: true, data: { executed: false, planToken: 't2', packageId: 'P', version: '1', command: 'c' } });
    assert.equal(m.takePlan('t1', 'P', '1').command, 'tcpkg install P=1 -y');
    assert.equal(m.takePlan('t1', 'P', '1'), null, 'used');
    assert.equal(m.takePlan('t2', 'P', '2'), null, 'other version');
    assert.equal(m.takePlan('t2', 'P', '1'), null, 'forgotten after the mismatch');
    m.addTarget('5.1.2.3.1.1');
    assert.equal(m.hasTarget('5.1.2.3.1.1'), true);
    assert.equal(m.hasTarget('5.1.2.3.1.2'), false);
    m.addIde('12|t');
    m.clearIdes();
    assert.equal(m.hasIde('12|t'), false);
  });

  test('consentBlockedBy: "consent:<gate kind>"', () => {
    assert.equal(consentBlockedBy(consentKind('WriteVariable', {})), 'consent:runtime');
    assert.equal(consentBlockedBy(consentKind('ConnectIde', { ProcessId: 1 })), 'consent:ide');
    assert.equal(consentBlockedBy(consentKind('ResetSolution', { Force: true })), 'consent:always');
    assert.equal(consentBlockedBy(consentKind('InstallPackage', { Approved: true })), 'consent:install');
  });

  test('consentErrorResult codes', () => {
    assert.equal(consentErrorResult('X', 'declined').error.code, 'CONSENT_DECLINED');
    for (const r of ['unsupported', 'failed', 'unknown-plan']) assert.equal(consentErrorResult('X', r).error.code, 'CONSENT_REQUIRED');
    const inst = consentErrorResult('InstallPackage', 'declined', { plan: { command: 'tcpkg install A=1 -y' } });
    assert.match(inst.error.hint, /tcpkg install A=1 -y/);
  });
});

// ---------------------------------------------------------------- end to end

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-consent258-'));
after(() => fs.rmSync(tmp, { recursive: true, force: true }));
let logN = 0;

/**
 * index.js with the consent fixture. elicitation: true -> the client declares capabilities.elicitation
 * and answers every elicitation/create with `h.answer(params)` (requests recorded in h.asked).
 */
async function start({ elicitation = true, env = {} } = {}) {
  const callLog = path.join(tmp, `calls-${++logN}.txt`);
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [INDEX],
    env: {
      ...process.env,
      TWINCAT_MCP_TOOLS_JSON: FIXTURE,
      TWINCAT_MCP_BRIDGE_COMMAND: process.execPath,
      TWINCAT_MCP_BRIDGE_ARGS: JSON.stringify([MOCK]),
      TWINCAT_MCP_MODAL_PROBE: '0',
      TWINCAT_MCP_SKIP_PID_CHECK: '1',
      MOCK_BRIDGE_CALL_LOG: callLog,
      ...env
    },
    stderr: 'pipe'
  });
  const client = new Client({ name: 'consent-test', version: '0.0.0' }, { capabilities: elicitation ? { elicitation: {} } : {} });
  const h = {
    client,
    asked: [],
    answer: () => ({ action: 'accept', content: { decision: 'approve' } }),
    async call(name, args = {}) {
      const r = await client.callTool({ name, arguments: args });
      return JSON.parse(r.content[0].text);
    },
    calls() {
      return fs.existsSync(callLog) ? fs.readFileSync(callLog, 'utf8').split(/\r?\n/).filter(Boolean) : [];
    },
    clearCalls() {
      fs.rmSync(callLog, { force: true });
    }
  };
  if (elicitation) {
    client.setRequestHandler(ElicitRequestSchema, async (req) => {
      h.asked.push(req.params);
      return h.answer(req.params);
    });
  }
  await client.connect(transport);
  return h;
}

const APPROVE = () => ({ action: 'accept', content: { decision: 'approve' } });
const answers = {
  decline: () => ({ action: 'decline' }),
  cancel: () => ({ action: 'cancel' }),
  'accept+reject': () => ({ action: 'accept', content: { decision: 'reject' } }),
  'accept+no field': () => ({ action: 'accept', content: {} })
};

// each gate: tool, arguments, cmdlet that must not run on a refusal, setup before the call
const GATES = [
  { tool: 'AddAdsRoute', args: { Name: 'CX', NetId: '5.9.9.9.1.1', Address: '10.0.0.9', DryRun: false }, cmdlet: 'Add-TcAdsRoute' },
  { tool: 'InstallLibrary', args: { LibraryPath: 'C:\\x.library', DryRun: false }, cmdlet: 'Install-TcLibrary' },
  { tool: 'UninstallLibrary', args: { LibraryName: 'Tc2_X', Version: '1.0.0', Distributor: 'Beckhoff', DryRun: false }, cmdlet: 'Uninstall-TcLibrary' },
  { tool: 'ResetSolution', args: { Force: true }, cmdlet: 'Reset-TcSolution' },
  { tool: 'ConnectIde', args: { ProcessId: 5555 }, cmdlet: 'Connect-TcIde' },
  { tool: 'WriteVariable', args: { Path: 'MAIN.x', Value: 1 }, cmdlet: 'Write-TcVariable', setup: (h) => h.call('ConnectAds', { AmsNetId: '5.1.2.3.1.1' }) },
  { tool: 'SetSystemState', args: { State: 'Run', AmsNetId: '5.1.2.3.1.1' }, cmdlet: 'Set-TcSystemState' },
  { tool: 'EnableConfig', args: { Force: true }, cmdlet: 'Enable-TcConfig', setup: (h) => h.call('ConnectAds', { AmsNetId: '5.1.2.3.1.1' }) }
];

describe('consent gate end to end: each gate', () => {
  for (const g of GATES) {
    describe(g.tool, () => {
      // one server per gate: the refusals first (nothing remembered), the approval last
      let h;
      before(async () => {
        h = await start();
        if (g.setup) await g.setup(h);
      });
      beforeEach(() => {
        h.clearCalls();
        h.asked.length = 0;
      });
      after(async () => h?.client.close());

      for (const [label, fn] of Object.entries(answers)) {
        test(`${label} -> CONSENT_DECLINED, bridge not called`, async () => {
          h.answer = fn;
          const r = await h.call(g.tool, g.args);
          assert.equal(h.asked.length, 1);
          assert.equal(r.success, false);
          assert.equal(r.error.code, 'CONSENT_DECLINED');
          assert.ok(r.error.hint);
          assert.equal(r.data.notRun, true);
          assert.deepEqual(h.calls(), []);
        });
      }

      test('elicitation handler throws -> CONSENT_REQUIRED, bridge not called', async () => {
        h.answer = () => {
          throw new Error('client failure');
        };
        const r = await h.call(g.tool, g.args);
        assert.equal(r.error.code, 'CONSENT_REQUIRED');
        assert.deepEqual(h.calls(), []);
      });

      test('accept + approve -> runs', async () => {
        h.answer = APPROVE;
        const r = await h.call(g.tool, g.args);
        assert.equal(h.asked.length, 1);
        assert.equal(r.success, true, JSON.stringify(r));
        assert.ok(h.calls().includes(g.cmdlet));
      });
    });
  }

  test('client without elicitation -> CONSENT_REQUIRED for every gate, bridge never called', async () => {
    const h = await start({ elicitation: false });
    try {
      await h.call('ConnectAds', { AmsNetId: '5.1.2.3.1.1' });
      h.clearCalls();
      for (const g of GATES) {
        const r = await h.call(g.tool, g.args);
        assert.equal(r.error.code, 'CONSENT_REQUIRED', g.tool);
        assert.match(r.error.hint, /interactive MCP client/);
      }
      assert.deepEqual(h.calls(), []);
    } finally {
      await h.client.close();
    }
  });
});

describe('consent gate end to end: runtime targets', () => {
  let h;
  before(async () => (h = await start()));
  after(async () => h?.client.close());

  test('local-umrt never asks', async () => {
    await h.call('ConnectAds', { AmsNetId: UMRT });
    const r = await h.call('WriteVariable', { Path: 'MAIN.x', Value: 1 });
    assert.equal(r.success, true);
    assert.equal((await h.call('EnableConfig', { Force: true })).success, true);
    assert.equal(h.asked.length, 0);
  });

  test('a real target asks once per AmsNetId in this server; another target asks again', async () => {
    h.asked.length = 0;
    await h.call('ConnectAds', { AmsNetId: '5.1.2.3.1.1' });
    assert.equal((await h.call('WriteVariable', { Path: 'MAIN.x', Value: 1 })).success, true);
    assert.equal((await h.call('EnableConfig', { Force: true })).success, true);
    assert.equal((await h.call('SetSystemState', { State: 'Run', AmsNetId: '5.1.2.3.1.1' })).success, true);
    assert.equal(h.asked.length, 1, 'second and third call on the same target: no form');
    assert.match(h.asked[0].message, /Target AmsNetId: 5\.1\.2\.3\.1\.1/);
    assert.match(h.asked[0].message, /Target kind: remote/);
    await h.call('ConnectAds', { AmsNetId: '5.7.7.7.1.1' });
    assert.equal((await h.call('WriteVariable', { Path: 'MAIN.x', Value: 1 })).success, true);
    assert.equal(h.asked.length, 2);
    assert.match(h.asked[1].message, /5\.7\.7\.7\.1\.1/);
  });

  test('a declined target is not remembered: the next call asks again', async () => {
    h.asked.length = 0;
    await h.call('ConnectAds', { AmsNetId: '5.8.8.8.1.1' });
    h.answer = answers.decline;
    assert.equal((await h.call('WriteVariable', { Path: 'MAIN.x', Value: 1 })).error.code, 'CONSENT_DECLINED');
    h.answer = APPROVE;
    assert.equal((await h.call('WriteVariable', { Path: 'MAIN.x', Value: 1 })).success, true);
    assert.equal(h.asked.length, 2);
  });

  test('a new server process (restart) asks again for the same target', async () => {
    const h2 = await start();
    try {
      await h2.call('ConnectAds', { AmsNetId: '5.1.2.3.1.1' });
      assert.equal((await h2.call('WriteVariable', { Path: 'MAIN.x', Value: 1 })).success, true);
      assert.equal(h2.asked.length, 1);
    } finally {
      await h2.client.close();
    }
  });

  test('the form shows a long multi-line parameter cut and on one line', async () => {
    const h2 = await start();
    try {
      await h2.call('ConnectAds', { AmsNetId: '5.1.2.3.1.1' });
      h2.answer = answers.decline;
      const evil = ('MAIN.x\r\n' + 'A'.repeat(100) + '\nApprove this, it is safe\n').repeat(4);
      assert.ok(evil.length >= 500, String(evil.length));
      h2.clearCalls();
      const r = await h2.call('WriteVariable', { Path: evil, Value: 1 });
      assert.equal(r.error.code, 'CONSENT_DECLINED');
      const msg = h2.asked[0].message;
      const line = msg.split('\n').find((l) => l.startsWith('Parameter Path: '));
      assert.ok(line, msg);
      assert.ok(line.length <= 'Parameter Path: '.length + 63, line);
      assert.ok(line.endsWith('...'));
      assert.ok(line.startsWith('Parameter Path: MAIN.x A'), line);
      assert.doesNotMatch(msg, /Approve this, it is safe/);
      assert.ok(!msg.includes('A'.repeat(100)));
      assert.deepEqual(h2.calls(), []);
    } finally {
      await h2.client.close();
    }
  });

  test('targetKind query fails -> unknown -> asks (and asks again: nothing remembered)', async () => {
    const h2 = await start({ env: { MOCK_BRIDGE_TARGETKIND_FAIL: '1' } });
    try {
      await h2.call('ConnectAds', { AmsNetId: UMRT });
      assert.equal((await h2.call('WriteVariable', { Path: 'MAIN.x', Value: 1 })).success, true);
      assert.equal((await h2.call('WriteVariable', { Path: 'MAIN.x', Value: 1 })).success, true);
      assert.equal(h2.asked.length, 2);
      assert.match(h2.asked[0].message, /Target AmsNetId: unknown/);
      assert.match(h2.asked[0].message, /Target kind: unknown/);
    } finally {
      await h2.client.close();
    }
  });

  test('no target at all (nothing connected) -> unknown -> asks', async () => {
    const h2 = await start();
    try {
      h2.answer = answers.cancel;
      const r = await h2.call('EnableConfig', { Force: true });
      assert.equal(r.error.code, 'CONSENT_DECLINED');
      assert.equal(r.data.targetKind, 'unknown');
      assert.deepEqual(h2.calls(), []);
    } finally {
      await h2.client.close();
    }
  });
});

describe('consent gate end to end: RunLifecycle', () => {
  test('the gate runs before its EnableConfig step: decline stops there, Enable-TcConfig never called', async () => {
    const h = await start();
    try {
      h.answer = answers.decline;
      const r = await h.call('RunLifecycle', { TargetAmsNetId: '5.1.2.3.1.1', SkipBuild: true });
      assert.equal(r.success, false);
      assert.equal(r.error.code, 'CONSENT_DECLINED');
      assert.equal(r.data.failedStep, 'EnableConfig');
      assert.equal(h.asked.length, 1);
      assert.ok(!h.calls().includes('Enable-TcConfig'), h.calls().join(','));
    } finally {
      await h.client.close();
    }
  });
});

describe('consent gate end to end: ConnectIde ProcessId', () => {
  let h;
  before(async () => (h = await start({ env: { MOCK_BRIDGE_IDE_LAUNCHED: '4242' } })));
  after(async () => h?.client.close());

  test('an IDE TcAuto launched (launch record) never asks', async () => {
    assert.equal((await h.call('ConnectIde', { ProcessId: 4242 })).success, true);
    assert.equal(h.asked.length, 0);
  });

  test('a user IDE asks once per IDE; DisconnectIde forgets it; another IDE asks', async () => {
    h.asked.length = 0;
    assert.equal((await h.call('ConnectIde', { ProcessId: 5555 })).success, true);
    assert.equal((await h.call('ConnectIde', { ProcessId: 5555 })).success, true);
    assert.equal(h.asked.length, 1);
    assert.match(h.asked[0].message, /IDE process id: 5555/);
    assert.equal((await h.call('ConnectIde', { ProcessId: 6666 })).success, true);
    assert.equal(h.asked.length, 2);
    await h.call('DisconnectIde');
    assert.equal((await h.call('ConnectIde', { ProcessId: 5555 })).success, true);
    assert.equal(h.asked.length, 3, 'asked again after DisconnectIde');
  });

  test('a process whose identity cannot be read asks every time', async () => {
    h.asked.length = 0;
    await h.call('ConnectIde', { ProcessId: 999 });
    await h.call('ConnectIde', { ProcessId: 999 });
    assert.equal(h.asked.length, 2);
  });
});

describe('consent gate end to end: InstallPackage', () => {
  let h;
  before(async () => (h = await start()));
  after(async () => h?.client.close());
  const PKG = { PackageId: 'TwinCAT.Standard.XAE', Version: '4024.71.5' };

  test('plan: no form, planToken returned as before', async () => {
    const r = await h.call('InstallPackage', PKG);
    assert.equal(r.success, true);
    assert.equal(r.data.executed, false);
    assert.match(r.data.planToken, /^mock-plan-/);
    assert.equal(h.asked.length, 0);
  });

  test('Approved with a token this server issued -> form shows the remembered plan; approve runs it', async () => {
    const plan = await h.call('InstallPackage', PKG);
    h.clearCalls();
    h.asked.length = 0;
    const r = await h.call('InstallPackage', { ...PKG, Approved: true, PlanToken: plan.data.planToken });
    assert.equal(r.success, true, JSON.stringify(r));
    assert.equal(r.data.executed, true);
    assert.equal(h.asked.length, 1);
    assert.match(h.asked[0].message, /Command: tcpkg install TwinCAT\.Standard\.XAE=4024\.71\.5 -y/);
    assert.doesNotMatch(h.asked[0].message, /mock-plan-/, 'the token is not shown');
    assert.deepEqual(h.calls(), ['Install-TcPackage']);
  });

  test('decline -> CONSENT_DECLINED with the tcpkg command; nothing installed', async () => {
    const plan = await h.call('InstallPackage', PKG);
    h.clearCalls();
    h.answer = answers.decline;
    const r = await h.call('InstallPackage', { ...PKG, Approved: true, PlanToken: plan.data.planToken });
    h.answer = APPROVE;
    assert.equal(r.error.code, 'CONSENT_DECLINED');
    assert.match(r.error.hint, /tcpkg install TwinCAT\.Standard\.XAE=4024\.71\.5 -y/);
    assert.equal(r.data.command, 'tcpkg install TwinCAT.Standard.XAE=4024.71.5 -y');
    assert.deepEqual(h.calls(), []);
  });

  test('unknown / reused / mismatched planToken -> CONSENT_REQUIRED without a form', async () => {
    h.asked.length = 0;
    h.clearCalls();
    const unknown = await h.call('InstallPackage', { ...PKG, Approved: true, PlanToken: 'made-up-token' });
    assert.equal(unknown.error.code, 'CONSENT_REQUIRED');
    assert.match(unknown.error.hint, /without Approved/);
    const none = await h.call('InstallPackage', { ...PKG, Approved: true });
    assert.equal(none.error.code, 'CONSENT_REQUIRED');
    const plan = await h.call('InstallPackage', PKG);
    h.clearCalls();
    const other = await h.call('InstallPackage', { ...PKG, Version: '4026.1.1', Approved: true, PlanToken: plan.data.planToken });
    assert.equal(other.error.code, 'CONSENT_REQUIRED');
    assert.equal(h.asked.length, 0);
    assert.deepEqual(h.calls(), []);
  });

  test('client without elicitation -> CONSENT_REQUIRED with the tcpkg command', async () => {
    const h2 = await start({ elicitation: false });
    try {
      const plan = await h2.call('InstallPackage', PKG);
      h2.clearCalls();
      const r = await h2.call('InstallPackage', { ...PKG, Approved: true, PlanToken: plan.data.planToken });
      assert.equal(r.error.code, 'CONSENT_REQUIRED');
      assert.match(r.error.hint, /tcpkg install TwinCAT\.Standard\.XAE=4024\.71\.5 -y/);
      assert.deepEqual(h2.calls(), []);
    } finally {
      await h2.client.close();
    }
  });
});

// TCAUTO_TRACE_FILE (lib/trace.js): a call the gate refused carries blockedBy on its own trace line;
// a call that passed the gate (or was never gated) has blockedBy null. Only the gate name is
// written: neither the form text nor the user's answer.
describe('consent gate end to end: tool-call trace blockedBy', () => {
  const traceFile = path.join(tmp, 'trace-consent.jsonl');
  const lines = () => fs.readFileSync(traceFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  let h;
  before(async () => (h = await start({ env: { TCAUTO_TRACE_FILE: traceFile } })));
  beforeEach(() => fs.rmSync(traceFile, { force: true }));
  after(async () => h?.client.close());

  test('declined -> blockedBy consent:runtime, CONSENT_DECLINED; approved -> blockedBy null', async () => {
    await h.call('ConnectAds', { AmsNetId: '5.1.2.3.1.1' });
    h.answer = answers.decline;
    const refused = await h.call('WriteVariable', { Path: 'MAIN.x', Value: 1 });
    assert.equal(refused.error.code, 'CONSENT_DECLINED');
    h.answer = APPROVE;
    assert.equal((await h.call('WriteVariable', { Path: 'MAIN.x', Value: 1 })).success, true);
    const recs = lines();
    assert.deepEqual(recs.map((r) => [r.tool, r.success, r.errorCode, r.blockedBy]), [
      ['ConnectAds', true, null, null],
      ['WriteVariable', false, 'CONSENT_DECLINED', 'consent:runtime'],
      ['WriteVariable', true, null, null]
    ]);
    assert.ok(recs[0].blockedBy === null && recs[2].blockedBy === null);
    const text = fs.readFileSync(traceFile, 'utf8');
    assert.doesNotMatch(text, /decision|approve|confirmation form/i, 'no form text or user answer in the trace');
  });

  test('elicitation fails -> blockedBy consent:ide, CONSENT_REQUIRED', async () => {
    h.answer = () => {
      throw new Error('client failure');
    };
    const r = await h.call('ConnectIde', { ProcessId: 7777 });
    assert.equal(r.error.code, 'CONSENT_REQUIRED');
    const [rec] = lines();
    assert.deepEqual([rec.tool, rec.success, rec.errorCode, rec.blockedBy], ['ConnectIde', false, 'CONSENT_REQUIRED', 'consent:ide']);
    h.answer = APPROVE;
  });

  test('composite: the refused EnableConfig step line has blockedBy, the RunLifecycle line has null', async () => {
    // a fresh server: the target approved by the first test is remembered in this one
    const h2 = await start({ env: { TCAUTO_TRACE_FILE: traceFile } });
    let r;
    try {
      h2.answer = answers.decline;
      r = await h2.call('RunLifecycle', { TargetAmsNetId: '5.1.2.3.1.1', SkipBuild: true });
    } finally {
      await h2.client.close();
    }
    assert.equal(r.error.code, 'CONSENT_DECLINED', JSON.stringify(r));
    const recs = lines();
    const parent = recs.find((x) => x.tool === 'RunLifecycle');
    const step = recs.find((x) => x.tool === 'EnableConfig');
    assert.equal(step.parentSeq, parent.seq);
    assert.deepEqual([step.success, step.errorCode, step.blockedBy], [false, 'CONSENT_DECLINED', 'consent:runtime']);
    assert.equal(parent.errorCode, 'CONSENT_DECLINED');
    assert.equal(parent.blockedBy, null, 'the composite itself was not refused by the gate');
    assert.ok(recs.filter((x) => x !== step).every((x) => x.blockedBy === null));
  });
});

// #237: the BRIDGE_* / IDE_MODAL_DIALOG hints decide "this session's IDE" vs "the user's IDE" from
// ConnectIde's data.ownedBySession (kept in lastIde), not from selectedBy === 'launched'.
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { ideFromConnectData, isOwnedBySession, ideHint, modalHint } from '../lib/ide-hints.js';

const CASES = [
  { name: 'launched', data: { ideProcessId: 4242, selectedBy: 'launched', ownedBySession: true }, owned: true },
  { name: 'orphan-takeover', data: { ideProcessId: 4242, selectedBy: 'orphan-takeover', ownedBySession: true }, owned: true },
  { name: 'session-launched', data: { ideProcessId: 4242, selectedBy: 'session-launched', ownedBySession: true }, owned: true },
  { name: 'user IDE (solution-match, ownedBySession false)', data: { ideProcessId: 4242, selectedBy: 'solution-match', ownedBySession: false }, owned: false },
  // conservative: no ownedBySession -> not ours, even when selectedBy says launched
  { name: 'ownedBySession missing', data: { ideProcessId: 4242, selectedBy: 'launched' }, owned: false },
  { name: 'ownedBySession not a boolean', data: { ideProcessId: 4242, selectedBy: 'launched', ownedBySession: 'true' }, owned: false }
];

describe('ideFromConnectData', () => {
  test('keeps ownedBySession only when it is the boolean true/false', () => {
    assert.equal(ideFromConnectData({ ownedBySession: true }).ownedBySession, true);
    assert.equal(ideFromConnectData({ ownedBySession: false }).ownedBySession, false);
    assert.equal(ideFromConnectData({}).ownedBySession, null);
    assert.equal(ideFromConnectData({ ownedBySession: 1 }).ownedBySession, null);
  });
  test('shape', () => {
    assert.deepEqual(ideFromConnectData({ ideProcessId: 7, selectedBy: 'orphan-takeover', solution: 'C:\\a.sln', ownedBySession: true }), {
      ideProcessId: 7,
      selectedBy: 'orphan-takeover',
      ownedBySession: true,
      solution: 'C:\\a.sln',
      ideMainHwnd: null
    });
    assert.deepEqual(ideFromConnectData(null), { ideProcessId: null, selectedBy: null, ownedBySession: null, solution: null, ideMainHwnd: null });
  });
});

describe('ownership decides the hint (#237)', () => {
  for (const c of CASES) {
    const ide = ideFromConnectData(c.data);
    test(`${c.name}: owned=${c.owned}`, () => {
      assert.equal(isOwnedBySession(ide), c.owned);
      const bridge = ideHint(ide);
      const modal = modalHint(4242, ide, 'Target system reports a fatal error', 'killed');
      if (c.owned) {
        for (const h of [bridge, modal]) {
          assert.match(h, /taskkill \/PID 4242 \/T \/F/);
          assert.match(h, /ask the user before killing it/);
          assert.doesNotMatch(h, /opened by the user/);
          // #263 review: a pid alone can be recycled -> confirm name + start time before taskkill;
          // DisconnectIde Kill cannot do it (the restarted bridge has no IDE state)
          assert.match(h, /first confirm pid 4242 is still that IDE/);
          assert.match(h, /Get-Process -Id 4242 \| Select-Object Name, StartTime/);
          assert.match(h, /DisconnectIde Quit=true Kill=true cannot kill it here/);
        }
        if (c.data.selectedBy === 'launched') assert.match(modal, /launched by this server/);
        else assert.match(modal, new RegExp(`owned by this session, selectedBy '${c.data.selectedBy}'`));
      } else {
        for (const h of [bridge, modal]) {
          assert.doesNotMatch(h, /taskkill/);
          assert.doesNotMatch(h, /launched by this server/);
          assert.doesNotMatch(h, /Get-Process/);
          assert.match(h, /not owned by this session/);
        }
      }
    });
  }
  test('no ide / no pid: ideHint null, modalHint treats the IDE as not owned', () => {
    assert.equal(ideHint(null), null);
    assert.equal(ideHint({ ideProcessId: null, ownedBySession: true }), null);
    assert.match(modalHint(4242, null, 'X', 'dequeued'), /not owned by this session/);
  });
});

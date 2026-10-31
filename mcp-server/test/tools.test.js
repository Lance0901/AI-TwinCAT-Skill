import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadToolCatalog, validateParams, computeTimeoutMs, toToolResult, buildCmdletNameMap, rewriteHintCmdletNames, rewriteResultHints, MAX_CALL_TIMEOUT_MS, MIN_CALL_TIMEOUT_MS } from '../lib/tools.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const catalog = loadToolCatalog(path.join(__dirname, 'fixtures', 'tools.fixture.json'));

describe('loadToolCatalog', () => {
  test('returns a Map keyed by tool name', () => {
    assert.equal(catalog.size, 3);
    assert.equal(catalog.get('ConnectIde').cmdlet, 'Connect-TcIde');
    assert.equal(catalog.meta.moduleVersion, '0.1.0');
  });
});

describe('validateParams', () => {
  const connect = catalog.get('ConnectIde');
  const read = catalog.get('ReadVariable');

  test('accepts known params and drops null/undefined', () => {
    const r = validateParams(connect, { ProgId: 'X', SolutionPath: null, NoLaunch: undefined });
    assert.deepEqual(r, { ok: true, params: { ProgId: 'X' } });
  });

  test('accepts missing args object', () => {
    assert.deepEqual(validateParams(connect, undefined), { ok: true, params: {} });
  });

  test('rejects unknown params with allowed-list hint', () => {
    const r = validateParams(connect, { Bogus: 1 });
    assert.equal(r.ok, false);
    assert.equal(r.error.code, 'INVALID_PARAMS');
    assert.equal(r.error.message, "Unknown parameter 'Bogus' for ConnectIde");
    assert.match(r.error.hint, /Allowed: ProgId, SolutionPath, NoLaunch/);
  });

  test('rejects missing required', () => {
    const r = validateParams(read, {});
    assert.equal(r.ok, false);
    assert.equal(r.error.code, 'INVALID_PARAMS');
    assert.match(r.error.message, /Missing required parameter 'Path'/);
  });

  test('required satisfied by null is still missing', () => {
    const r = validateParams(read, { Path: null });
    assert.equal(r.ok, false);
    assert.match(r.error.message, /Missing required parameter 'Path'/);
  });

  test('checks enum', () => {
    assert.equal(validateParams(read, { Path: ['a'], Mode: 'Raw' }).ok, true);
    const r = validateParams(read, { Path: ['a'], Mode: 'Bogus' });
    assert.equal(r.ok, false);
    assert.match(r.error.message, /must be one of "Value", "Raw"/);
  });

  test('checks basic types', () => {
    assert.equal(validateParams(connect, { ProgId: 5 }).ok, false);
    assert.equal(validateParams(connect, { NoLaunch: 'yes' }).ok, false);
    assert.equal(validateParams(read, { Path: 'MAIN.x' }).ok, false, 'string is not an array');
    assert.equal(validateParams(read, { Path: [1] }).ok, false, 'array items must be strings');
    assert.equal(validateParams(read, { Path: [] }).ok, false, 'minItems 1');
    assert.equal(validateParams(read, { Path: ['a'], TimeoutMs: 1.5 }).ok, false, 'integer');
    assert.equal(validateParams(read, { Path: ['a'], TimeoutMs: 1500 }).ok, true);
  });

  test('{} schema accepts anything', () => {
    const tool = { name: 'T', inputSchema: { type: 'object', properties: { Any: {} } } };
    assert.equal(validateParams(tool, { Any: { nested: [1, 2] } }).ok, true);
    assert.equal(validateParams(tool, { Any: 'str' }).ok, true);
  });

  test('rejects non-object arguments', () => {
    assert.equal(validateParams(connect, 'nope').ok, false);
    assert.equal(validateParams(connect, [1]).ok, false);
  });

  test('checks minimum / maximum on integer and number', () => {
    assert.equal(validateParams(read, { Path: ['a'], TimeoutMs: 1 }).ok, true);
    assert.equal(validateParams(read, { Path: ['a'], TimeoutMs: 600000 }).ok, true);
    const low = validateParams(read, { Path: ['a'], TimeoutMs: 0 });
    assert.equal(low.ok, false);
    assert.equal(low.error.code, 'INVALID_PARAMS');
    assert.match(low.error.message, /TimeoutMs.*>= 1, got 0/);
    const high = validateParams(read, { Path: ['a'], TimeoutMs: 99999999 });
    assert.equal(high.ok, false);
    assert.match(high.error.message, /TimeoutMs.*<= 600000, got 99999999/);

    const tool = { name: 'T', inputSchema: { type: 'object', properties: { Ratio: { type: 'number', minimum: 0, maximum: 1 } } } };
    assert.equal(validateParams(tool, { Ratio: 0.5 }).ok, true);
    assert.equal(validateParams(tool, { Ratio: 1.5 }).ok, false);
    assert.equal(validateParams(tool, { Ratio: -0.1 }).ok, false);
  });

  test('object values: empty key or keys differing only in case -> INVALID_PARAMS (PS 5.1 ConvertFrom-Json)', () => {
    const tool = {
      name: 'T',
      inputSchema: {
        type: 'object',
        properties: { Values: { type: 'object' }, Any: {}, List: { type: 'array', items: { type: 'object' } } }
      }
    };
    assert.equal(validateParams(tool, { Values: { Name: 'x', Age: 1, nested: { Deep: [{ ok: true }] } } }).ok, true);

    const empty = validateParams(tool, { Values: { '': 1 } });
    assert.equal(empty.ok, false);
    assert.equal(empty.error.code, 'INVALID_PARAMS');
    assert.match(empty.error.message, /Parameter 'Values' of T contains an empty property name/);

    const dup = validateParams(tool, { Values: { Name: 'x', name: 'y' } });
    assert.equal(dup.ok, false);
    assert.match(dup.error.message, /properties 'Name' and 'name' that differ only in case/);

    const nested = validateParams(tool, { Any: { outer: { A: 1, a: 2 } } });
    assert.equal(nested.ok, false);
    assert.match(nested.error.message, /Parameter 'Any' of T\.outer contains properties 'A' and 'a'/);

    const inArray = validateParams(tool, { List: [{ ok: 1 }, { '': 2 }] });
    assert.equal(inArray.ok, false);
    assert.match(inArray.error.message, /Parameter 'List' of T\[1\] contains an empty property name/);

    const deepArray = validateParams(tool, { Any: [[{ X: 1, x: 2 }]] });
    assert.equal(deepArray.ok, false);
  });
});

describe('computeTimeoutMs', () => {
  test('uses tool.timeoutMs (or 120000 default) when no timing args', () => {
    assert.equal(computeTimeoutMs({ timeoutMs: 2000 }, {}), 2000);
    assert.equal(computeTimeoutMs({}, {}), 120000);
    assert.equal(computeTimeoutMs({ timeoutMs: 600000 }), 600000);
  });

  test('TimeoutSec*1000 + 30000 wins when larger', () => {
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutSec: 300 }), 330000);
    assert.equal(computeTimeoutMs({ timeoutMs: 600000 }, { TimeoutSec: 10 }), 600000);
  });

  test('TimeoutMs + DurationMs + 30000 wins when larger', () => {
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutMs: 100000, DurationMs: 50000 }), 180000);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { DurationMs: 100000 }), 130000);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutMs: 5000 }), 120000);
  });

  test('UntilTimeoutMs counts like TimeoutMs', () => {
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { UntilTimeoutMs: 200000 }), 230000);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutMs: 100000, UntilTimeoutMs: 50000, DurationMs: 10000 }), 190000);
  });

  test('result is clamped to [1 s, 2 h] so setTimeout never overflows', () => {
    assert.equal(MIN_CALL_TIMEOUT_MS, 1000);
    assert.equal(MAX_CALL_TIMEOUT_MS, 7_200_000);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutSec: 99999999 }), MAX_CALL_TIMEOUT_MS);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutMs: Number.MAX_SAFE_INTEGER }), MAX_CALL_TIMEOUT_MS);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutSec: Infinity }), 120000, 'non-finite values are ignored (cannot come from JSON)');
    assert.equal(computeTimeoutMs({ timeoutMs: 10 }, {}), MIN_CALL_TIMEOUT_MS);
    assert.equal(computeTimeoutMs({ timeoutMs: 7_200_000 }, { TimeoutSec: 7200 }), MAX_CALL_TIMEOUT_MS);
    assert.equal(computeTimeoutMs({ timeoutMs: 600000 }, { TimeoutSec: 3600 }), 3630000, 'inside the range: untouched');
  });
});

describe('toToolResult', () => {
  test('success result is not an error and carries structuredContent', () => {
    const r = toToolResult({ success: true, data: { a: 1 } });
    assert.equal(r.isError, false);
    assert.deepEqual(r.structuredContent, { success: true, data: { a: 1 } });
    assert.equal(r.content[0].type, 'text');
    assert.deepEqual(JSON.parse(r.content[0].text), { success: true, data: { a: 1 } });
  });

  test('failure result is an error', () => {
    const r = toToolResult({ success: false, error: { code: 'X', message: 'm' } });
    assert.equal(r.isError, true);
    assert.match(r.content[0].text, /"code": "X"/);
  });
});

describe('cmdlet name rewriting in hints', () => {
  const names = buildCmdletNameMap(catalog, {
    'Enter-TcPlcOnline': 'PlcLogin',
    'Reset-TcSolution': 'ResetSolution',
    'Connect-TcAds': 'ConnectAds',
    'Set-TcPlcState': 'SetPlcState',
    'Enable-TcConfig': 'EnableConfig',
    'Disconnect-TcIde': 'DisconnectIde',
    'Get-TcIdeModalDialog': 'GetIdeModalDialog',
    'Set-TcTarget': 'SetTarget'
  });
  const rw = (s) => rewriteHintCmdletNames(s, names);

  test('loadToolCatalog builds byCmdlet', () => {
    assert.equal(catalog.byCmdlet.get('Connect-TcIde'), 'ConnectIde');
    assert.equal(names.get('Connect-TcIde'), 'ConnectIde');
    assert.equal(names.get('Get-TcIdeModalDialog'), 'GetIdeModalDialog');
  });

  test('plain names, parameters and unknown cmdlets', () => {
    assert.equal(rw('Enter-TcPlcOnline'), 'PlcLogin');
    assert.equal(rw('Reset-TcSolution'), 'ResetSolution');
    assert.equal(rw('呼叫 Connect-TcAds'), '呼叫 ConnectAds');
    assert.equal(rw('Connect-TcIde -SolutionPath <sln>'), 'ConnectIde SolutionPath=<sln>');
    assert.equal(rw('Set-TcPlcState -State Run'), 'SetPlcState State=Run');
    assert.equal(rw('Enable-TcConfig -Force'), 'EnableConfig Force=true');
    assert.equal(rw('Disconnect-TcIde -Quit(或 kill IDE)'), 'DisconnectIde Quit=true(或 kill IDE)');
    assert.equal(rw('Foo-TcBar -X 1'), 'Foo-TcBar -X 1');
  });

  test('quoted parameter values stay whole (ACTIVATE_FAILED hint)', () => {
    assert.equal(
      rw("執行 Set-TcTarget -AmsNetId 199.5.42.250.1.1 -Platform 'TwinCAT OS (x64)'(Usermode Runtime / UmRT),再重跑 Build-TcProject"),
      "執行 SetTarget AmsNetId=199.5.42.250.1.1 Platform='TwinCAT OS (x64)'(Usermode Runtime / UmRT),再重跑 BuildProject"
    );
    assert.equal(rw('Set-TcTarget -Platform "TwinCAT RT (x64)" -Configuration Release'), 'SetTarget Platform="TwinCAT RT (x64)" Configuration=Release');
  });

  test('real mixed Chinese sentence', () => {
    assert.equal(
      rw('PLC runtime port 851 不存在:程式尚未下載或 PLC 未啟動。先 Enter-TcPlcOnline,再 Set-TcPlcState -State Run'),
      'PLC runtime port 851 不存在:程式尚未下載或 PLC 未啟動。先 PlcLogin,再 SetPlcState State=Run'
    );
  });

  // Tree tool hints name the cmdlet only; the rewrite turns it into the tool name (phase1-2.8.md #5:
  // "LookupTreeItem (Get-TcTreeItem)" used to become "LookupTreeItem (LookupTreeItem)").
  test('tree tool hints: cmdlet names become tool names, nothing doubled', () => {
    // the real tools.json: these cmdlets are not all in the fixture
    const real = buildCmdletNameMap(loadToolCatalog(path.join(__dirname, '..', 'tools.json')));
    const rw = (s) => rewriteHintCmdletNames(s, real);
    assert.equal(
      rw("'TIRT^NoSuchTask' not found: nearest existing parent is 'TIRT'. Use Get-TcTreeItem -Path 'TIRT' to browse."),
      "'TIRT^NoSuchTask' not found: nearest existing parent is 'TIRT'. Use LookupTreeItem Path='TIRT' to browse."
    );
    assert.equal(rw('Use Get-TcTreeItem on one of them, or Get-TcProjectTree.'), 'Use LookupTreeItem on one of them, or GetProjectTree.');
    assert.equal(rw('先用 Get-TcTreeItem 或 Get-TcProjectTree 查到確切路徑再重試'), '先用 LookupTreeItem 或 GetProjectTree 查到確切路徑再重試');
    assert.equal(rw('先 Exit-TcPlcOnline,再重跑同一個 tool'), '先 PlcLogout,再重跑同一個 tool');
    assert.equal(
      rw("rerun Export-TcTreeItem -Path 'TIPC^Plc^Plc Project^POUs' -FilePath 'C:\\Temp\\My Export\\POUs.zip'. Import it again with Import-TcTreeItem (the .zip file)."),
      "rerun ExportChild Path='TIPC^Plc^Plc Project^POUs' FilePath='C:\\Temp\\My Export\\POUs.zip'. Import it again with ImportChild (the .zip file)."
    );
    assert.doesNotMatch(rw('Use Get-TcTreeItem -Path \'TIRT\''), /LookupTreeItem \(LookupTreeItem\)/);
  });

  // phase2-3.8.md P1: every row of the table, with the real tools.json (switch vs value parameters).
  describe('phase2-3.8 P1 rows (real tools.json)', () => {
    const real = buildCmdletNameMap(loadToolCatalog(path.join(__dirname, '..', 'tools.json')), { 'Get-TcIdeModalDialog': 'GetIdeModalDialog' });
    const rw = (s) => rewriteHintCmdletNames(s, real);

    test('AddPouMember parent-kind: a switch does not swallow the next word; a lone -ParentPath', () => {
      assert.equal(
        rw('Look the parent up with Get-TcProjectTree -PlcOnly and pass its path as -ParentPath.'),
        'Look the parent up with GetProjectTree PlcOnly=true and pass its path as ParentPath.'
      );
    });

    test('TASK_CREATE_FAILED: -DryRun $false and the -AllowNoExport switch after it', () => {
      assert.equal(
        rw('都用 Remove-TcTreeItem -Path <path> -ConfirmName <Name> -DryRun $false -AllowNoExport,再重跑 Add-TcPlcTask'),
        '都用 DeleteChild Path=<path> ConfirmName=<Name> DryRun=false AllowNoExport=true,再重跑 AddPlcTask'
      );
    });

    test('TASK_NOT_FOUND / TASK_PROGRAM_ALREADY_LINKED: -DryRun $false and -DryRun:$false', () => {
      assert.equal(
        rw('用 data.plcTasks 裡的名稱當 -PlcTask 重跑;要新的 task 先 Add-TcPlcTask -Name <Name> -CycleTimeUs <us> -DryRun $false'),
        '用 data.plcTasks 裡的名稱當 PlcTask 重跑;要新的 task 先 AddPlcTask Name=<Name> CycleTimeUs=<us> DryRun=false'
      );
      assert.equal(
        rw('先 Remove-TcTaskProgram -ProgramName <data.existingLink> -PlcTask <舊 task> -DryRun $false,再 Add-TcTaskProgram -ProgramName <data.existingLink>'),
        '先 UnlinkProgramFromTask ProgramName=<data.existingLink> PlcTask=<舊 task> DryRun=false,再 LinkProgramToTask ProgramName=<data.existingLink>'
      );
      assert.equal(rw('Add-TcPlcTask -Name FastTask -DryRun:$false'), 'AddPlcTask Name=FastTask DryRun=false');
      assert.equal(rw('先 -DryRun $true 看預告'), '先 DryRun=true 看預告');
    });

    test('POU_CREATE_FAILED: a value parameter given without a value never becomes =true', () => {
      assert.equal(
        rw('用 Get-TcProjectTree -PlcOnly 找 <Plc> Project^POUs 的 path,當 -PlcProjectPath <path> 重跑同一個 tool;'),
        '用 GetProjectTree PlcOnly=true 找 <Plc> Project^POUs 的 path,當 PlcProjectPath=<path> 重跑同一個 tool;'
      );
      assert.equal(rw('後給 Add-TcPou -PlcProjectPath;0x98510001'), '後給 AddPou PlcProjectPath=<PlcProjectPath>;0x98510001');
      assert.doesNotMatch(rw('後給 Add-TcPou -PlcProjectPath;'), /PlcProjectPath=true/);
    });

    test('messages: AddInterface exists, UninstallLibrary wildcard', () => {
      assert.equal(
        rw("exists: an object named 'I_A' already exists at 'TIPC^P^P Project^POUs^I_A'. Pick another name, or change it with Write-TcPouCode -PouPath 'TIPC^P^P Project^POUs^I_A'."),
        "exists: an object named 'I_A' already exists at 'TIPC^P^P Project^POUs^I_A'. Pick another name, or change it with WritePouCode PouPath='TIPC^P^P Project^POUs^I_A'."
      );
      assert.equal(
        rw("-Version '3.*' contains a wildcard; Uninstall-TcLibrary removes exactly one installed version. Nothing was uninstalled."),
        "Version='3.*' contains a wildcard; UninstallLibrary removes exactly one installed version. Nothing was uninstalled."
      );
    });

    test('AddPlcTask verifyHint, UnlinkProgramFromTask warning, ImportPlcOpen restore / how, buildRequired', () => {
      assert.equal(
        rw("After Enable-TcConfig -Force, find n with Read-TcVariable -Path 'TwinCAT_SystemInfoVarList._TaskInfo[n].TaskName' (n = task index)"),
        "After EnableConfig Force=true, find n with ReadVariable Path=['TwinCAT_SystemInfoVarList._TaskInfo[n].TaskName'] (n = task index)"
      );
      assert.equal(
        rw("copy it back over 'C:\\S\\P38Task.TcTTO', then Reset-TcSolution."),
        "copy it back over 'C:\\S\\P38Task.TcTTO', then ResetSolution."
      );
      assert.equal(
        rw("Import-TcPlcOpen -FilePath 'C:\\S\\.tcauto-backup\\x.xml' -Option Replace -DryRun $false"),
        "ImportPlcOpen FilePath='C:\\S\\.tcauto-backup\\x.xml' Option=Replace DryRun=false"
      );
      assert.equal(
        rw("after the XML restore, copy 'a' over 'b' and run Reset-TcSolution (not measured); or Import-TcTreeItem of 'c.zip' (not measured)"),
        "after the XML restore, copy 'a' over 'b' and run ResetSolution (not measured); or ImportChild of 'c.zip' (not measured)"
      );
      assert.equal(rw('PLC code changed by Add-TcInterface I_P38Base'), 'PLC code changed by AddInterface I_P38Base');
    });

    test('lone PowerShell parameters, arrays, enums; switches of the named tool', () => {
      assert.equal(
        rw("invalid-selection = -Selection 每個元素一個物件(-Selection 'POUs.FB_A','DUTs.ST_B'),不要用 ^"),
        "invalid-selection = Selection 每個元素一個物件(Selection=['POUs.FB_A','DUTs.ST_B']),不要用 ^"
      );
      assert.equal(rw("Export-TcPlcOpen -Selection 'POUs.FB_A' -FilePath <x>"), "ExportPlcOpen Selection=['POUs.FB_A'] FilePath=<x>");
      assert.equal(rw('換一個 -Name;給 -ReturnType,或拿掉 -Access / -Language'), '換一個 Name;給 ReturnType,或拿掉 Access / Language');
      assert.equal(rw('不需要覆蓋就改用 -Option Rename'), '不需要覆蓋就改用 Option=Rename');
      assert.equal(rw('換一個 -FilePath,或加 -Overwrite 重跑 Save-TcArchive'), '換一個 FilePath,或加 Overwrite=true 重跑 SaveArchive');
      assert.equal(rw("Extends: -Extends 'I_Base'"), "Extends: Extends='I_Base'");
      assert.equal(rw('Get-TcLibraries -Repository 確認'), 'GetLibraries Repository=true 確認');
      assert.equal(rw('-Kind Library'), 'Kind=Library');
      // not a known parameter, inside a word, or a number: untouched
      assert.equal(rw('-NoSuchParam x; a-Name; -1'), '-NoSuchParam x; a-Name; -1');
    });

    // review S5: what must NOT be rewritten
    test('counter-examples: code, plain words, quoted text and paths stay as they are', () => {
      assert.equal(rw('x := -Value'), 'x := -Value');
      assert.equal(rw('x=-Value; y > -Name'), 'x=-Value; y > -Name');
      // '=' with blanks around it in prose is no operator
      assert.equal(rw('invalid-selection = -Selection per object'), 'invalid-selection = Selection per object');
      assert.equal(rw("set it with 'x := -Value'"), "set it with 'x := -Value'");
      // a lone parameter followed by a plain word: the word is not its value
      assert.equal(rw('-Path and then retry'), 'Path and then retry');
      // after a cmdlet: a lower-case English word is not a value
      assert.equal(rw('Get-TcTreeItem -Path and then retry'), 'LookupTreeItem Path=<Path> and then retry');
      // paths with ' -Name' inside, in quotes and outside
      assert.equal(rw("copy 'C:\\Proj\\My -Name dir\\x.plcproj' back"), "copy 'C:\\Proj\\My -Name dir\\x.plcproj' back");
      assert.equal(rw('copy C:\\Proj\\My -Name dir\\x.plcproj back'), 'copy C:\\Proj\\My -Name dir\\x.plcproj back');
      assert.equal(
        rw("Import-TcPlcOpen -FilePath 'C:\\Proj\\My -Name dir\\a.xml' -Option Replace"),
        "ImportPlcOpen FilePath='C:\\Proj\\My -Name dir\\a.xml' Option=Replace"
      );
      // an unquoted path value: a following -X that is not a parameter of the tool ends the call
      assert.equal(rw('Export-TcPlcOpen -FilePath C:\\Proj\\My -Name dir\\a.xml'), 'ExportPlcOpen FilePath=C:\\Proj\\My -Name dir\\a.xml');
      // identifier-like and numeric values after a cmdlet are still values
      assert.equal(rw('Add-TcPlcTask -Name FastTask -CycleTimeUs 1000'), 'AddPlcTask Name=FastTask CycleTimeUs=1000');
      assert.equal(rw("Get-TcTreeItem -Path TIPC^P^P Project"), 'LookupTreeItem Path=TIPC^P^P Project');
      // contractions are no quotes
      assert.equal(rw("doesn't matter: give -Name"), "doesn't matter: give Name");
    });

    test('rewriteResultHints covers message, verifyHint, warnings, restore, how, buildRequired', () => {
      const r = {
        success: false,
        error: { code: 'X', message: 'or change it with Write-TcPouCode -PouPath FB_X', hint: '重跑 Add-TcPlcTask -DryRun $false' },
        data: {
          verifyHint: 'After Enable-TcConfig -Force',
          warnings: ['then Reset-TcSolution.'],
          backup: { restore: 'Import-TcPlcOpen -Option Replace -DryRun $false', diskOnly: [{ how: 'run Reset-TcSolution' }] },
          buildRequired: 'PLC code changed by Add-TcInterface I_A',
          code: 'Add-TcPou stays',
          path: 'C:\\Add-TcPou'
        }
      };
      rewriteResultHints(r, real);
      assert.equal(r.error.message, 'or change it with WritePouCode PouPath=FB_X');
      assert.equal(r.error.hint, '重跑 AddPlcTask DryRun=false');
      assert.equal(r.data.verifyHint, 'After EnableConfig Force=true');
      assert.deepEqual(r.data.warnings, ['then ResetSolution.']);
      assert.equal(r.data.backup.restore, 'ImportPlcOpen Option=Replace DryRun=false');
      assert.equal(r.data.backup.diskOnly[0].how, 'run ResetSolution');
      assert.equal(r.data.buildRequired, 'PLC code changed by AddInterface I_A');
      assert.equal(r.data.code, 'Add-TcPou stays');
      assert.equal(r.data.path, 'C:\\Add-TcPou');
    });
  });

  test('rewriteResultHints: error.hint, nested steps, data.hint, harmless on junk', () => {
    const a = { success: false, error: { code: 'X', hint: '呼叫 Connect-TcAds' } };
    assert.equal(rewriteResultHints(a, names), a);
    assert.equal(a.error.hint, '呼叫 ConnectAds');
    const b = { success: false, data: { steps: [{ result: { error: { hint: 'Reset-TcSolution' } } }] } };
    rewriteResultHints(b, names);
    assert.equal(b.data.steps[0].result.error.hint, 'ResetSolution');
    const c = { success: true, data: { hint: 'try Enter-TcPlcOnline' } };
    rewriteResultHints(c, names);
    assert.equal(c.data.hint, 'try PlcLogin');
    assert.equal(rewriteResultHints(null, names), null);
    assert.equal(rewriteResultHints('Reset-TcSolution', names), 'Reset-TcSolution');
    assert.deepEqual(rewriteResultHints({ success: true, data: { a: 1 } }, names), { success: true, data: { a: 1 } });
  });
});

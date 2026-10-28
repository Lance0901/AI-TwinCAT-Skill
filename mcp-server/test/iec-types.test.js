// Unit tests for the PLC type conversion behind ReadVariable/WriteVariable:
//   * the module's IEC literal parser/formatter and numeric coercion (Private/ConvertTo-TcIecValue.ps1)
//   * bridge.ps1 ConvertTo-BridgeValue for the [object] Value parameter (JSON value passes through
//     untouched, so the cmdlet does the conversion and reports the typed value in data.written)
// Both run in a real Windows PowerShell 5.1 process (win32 only; skipped elsewhere), no TwinCAT needed.
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { defaultPowershellPath } from '../lib/config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MODULE = path.join(__dirname, '..', '..', 'src', 'TwinCATAutomation', 'TwinCATAutomation.psm1');
const BRIDGE = path.join(__dirname, '..', 'bridge', 'bridge.ps1');
const isWin = process.platform === 'win32';

function runPs(script) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-iec-'));
  const file = path.join(dir, 'case.ps1');
  // BOM so that PS 5.1 reads the script (and the non-ASCII module path) as UTF-8
  fs.writeFileSync(file, '﻿' + script, 'utf8');
  try {
    const r = spawnSync(defaultPowershellPath(), ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file], {
      encoding: 'utf8', windowsHide: true, timeout: 120000
    });
    assert.equal(r.status, 0, `powershell exited ${r.status}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
    const line = r.stdout.split(/\r?\n/).find((l) => l.startsWith('{') || l.startsWith('['));
    assert.ok(line, `no JSON line in stdout:\n${r.stdout}\n${r.stderr}`);
    return JSON.parse(line);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// Module scope access: the helpers are private, so call them through the module object.
function moduleScript(body) {
  return `
$ErrorActionPreference = 'Stop'
Import-Module '${MODULE.replace(/'/g, "''")}' -Force 3>$null
$m = Get-Module TwinCATAutomation
$out = & $m {
${body}
}
[Console]::Out.Write(($out | ConvertTo-Json -Compress -Depth 6))
[Console]::Out.Write("\`n")
`;
}

describe('IEC time/date conversion (module private helpers)', { skip: !isWin && 'Windows PowerShell only' }, () => {
  test('ConvertFrom-TcIecLiteral + Format-TcIecLiteral round-trip every supported form', () => {
    const cases = [
      ['TIME', 'T#2s500ms', 2500, 'T#2s500ms'],
      ['TIME', 3000, 3000, 'T#3s'],
      ['TIME', '3000', 3000, 'T#3s'],
      ['TIME', 'T#1m30s500ms', 90500, 'T#1m30s500ms'],
      ['TIME', 'T#2.5s', 2500, 'T#2s500ms'],
      ['TIME', '5s', 5000, 'T#5s'],
      ['TIME', 'T#1d2h3m4s5ms', 93784005, 'T#1d2h3m4s5ms'],
      ['TIME', 0, 0, 'T#0ms'],
      ['LTIME', 'LTIME#1us', 1000, 'LTIME#1us'],
      ['LTIME', 'T#1s', 1000000000, 'LTIME#1s'],
      ['TOD', 'TOD#12:30:00', 45000000, 'TOD#12:30:00'],
      ['TOD', 'TOD#12:30:00.500', 45000500, 'TOD#12:30:00.500'],
      ['TIME_OF_DAY', '12:30', 45000000, 'TOD#12:30:00'],
      ['DATE', 'D#2026-10-20', 1792454400, 'D#2026-10-20'],
      ['DATE', '2026-10-20', 1792454400, 'D#2026-10-20'],
      ['DT', 'DT#2026-10-20-12:30:00', 1792499400, 'DT#2026-10-20-12:30:00'],
      ['DT', '2026-10-20T12:30:00', 1792499400, 'DT#2026-10-20-12:30:00'],
      ['DT', '2026-10-20T12:30:00+08:00', 1792470600, 'DT#2026-10-20-04:30:00'],
      ['DATE_AND_TIME', '2026-10-20 12:30:00Z', 1792499400, 'DT#2026-10-20-12:30:00'],
      ['DT', 1792495907, 1792495907, 'DT#2026-10-20-11:31:47'],
      ['LDT', 'LDT#2026-10-20-12:30:00.123456789', '1792499400123456789', 'LDT#2026-10-20-12:30:00.123456789'],
      ['TIME', 'WRAPPED:T#6000ms', 6000, 'T#6s'],   // PSObject-wrapped string
      ['TIME', 'WRAPPED:3000', 3000, 'T#3s']        // PSObject-wrapped number
    ];
    const body = `
$cases = ConvertFrom-Json -InputObject '${JSON.stringify(cases.map(([t, v]) => ({ t, v }))).replace(/'/g, "''")}'
$res = @()
foreach ($c in $cases) {
  $ti = Get-TcIecTimeType -TypeName $c.t
  $v = $c.v
  if ($v -is [string] -and $v.StartsWith('WRAPPED:')) { $inner = $v.Substring(8); if ($inner -match '^\\d+$') { $inner = [int]$inner }; $v = [PSObject]::AsPSObject($inner) }
  $raw = ConvertFrom-TcIecLiteral -Value $v -TypeInfo $ti
  $res += [PSCustomObject]@{ raw = [string]$raw; text = (Format-TcIecLiteral -Raw $raw -TypeInfo $ti) }
}
, $res`;
    const out = runPs(moduleScript(body));
    assert.equal(out.length, cases.length);
    cases.forEach(([t, v, raw, text], i) => {
      assert.equal(out[i].raw, String(raw), `${t} ${v}: raw`);
      assert.equal(out[i].text, text, `${t} ${v}: text`);
    });
  });

  test('ConvertFrom-TcIecLiteral rejects wrong family, negatives, fractions, overflow, bad dates', () => {
    const cases = [
      ['TIME', 'DT#2026-01-01-00:00:00', /is a dt literal but the symbol is TIME/],
      ['TIME', 'T#-5s', /unsigned/],
      ['TIME', 'T#1us', /finer than the ms resolution/],
      ['TIME', 'abc', /not a duration literal/],
      ['TIME', 2.5, /not an integer/],
      ['TIME', 99999999999, /out of range for TIME/],
      ['DT', '2026-13-01T00:00:00', /not a valid date/],
      ['TOD', 'TOD#25:00:00', /not a valid time of day/],
      ['DATE', 'D#1960-01-01', /before 1970-01-01/],
      ['TIME', '99999999999999999999999', /out of range for TIME/],
      ['TIME', true, /BOOL value/],
      ['TIME', { a: 1 }, /JSON object\/array/]
    ];
    const body = `
$cases = ConvertFrom-Json -InputObject '${JSON.stringify(cases.map(([t, v]) => ({ t, v }))).replace(/'/g, "''")}'
$res = @()
foreach ($c in $cases) {
  $ti = Get-TcIecTimeType -TypeName $c.t
  try { $null = ConvertFrom-TcIecLiteral -Value $c.v -TypeInfo $ti; $res += 'NO ERROR' }
  catch { $res += $_.Exception.Message }
}
, $res`;
    const out = runPs(moduleScript(body));
    cases.forEach(([t, v, re], i) => assert.match(out[i], re, `${t} ${JSON.stringify(v)}`));
  });

  test('ConvertTo-TcTypedValue: numeric strings become numbers, no rounding, range checked, BOOL forms', () => {
    const cases = [
      ['Int16', '5', 5, 'Int16'],
      ['Int16', 5.0, 5, 'Int16'],
      ['Int16', '70.0', 70, 'Int16'],
      ['Double', '70.0', 70, 'Double'],
      ['Double', 0.1, 0.1, 'Double'],
      ['Single', 1.5, 1.5, 'Single'],
      ['Boolean', 'false', false, 'Boolean'],
      ['Boolean', 1, true, 'Boolean'],
      ['UInt32', 4294967295, 4294967295, 'UInt32'],
      ['Int16', 'WRAPPED:5', 5, 'Int16'],        // PSObject-wrapped value (pipeline / (Write-Output 5) / 1e3)
      ['Double', 'WRAPPED:2.5', 2.5, 'Double']
    ];
    const bad = [
      ['Int16', 70000, /out of range for Int16 \(-32768\.\.32767\)/],
      ['UInt16', -1, /out of range/],
      ['Int16', 2.5, /not an integer/],
      ['Boolean', 'yes', /not a BOOL/],
      ['Int32', 'abc', /not a number/],
      ['Int32', [1, 2], /JSON object\/array/]
    ];
    const body = `
$cases = ConvertFrom-Json -InputObject '${JSON.stringify([...cases, ...bad].map(([t, v]) => ({ t, v }))).replace(/'/g, "''")}'
$res = @()
foreach ($c in $cases) {
  $type = [type]('System.' + $c.t)
  $v = $c.v
  if ($v -is [string] -and $v.StartsWith('WRAPPED:')) { $v = [PSObject]::AsPSObject([double]::Parse($v.Substring(8), [Globalization.CultureInfo]::InvariantCulture)) }
  try { $x = ConvertTo-TcTypedValue -Value $v -Type $type -TypeName $c.t; $res += [PSCustomObject]@{ ok = $true; value = $x; type = $x.GetType().Name } }
  catch { $res += [PSCustomObject]@{ ok = $false; error = $_.Exception.Message } }
}
, $res`;
    const out = runPs(moduleScript(body));
    cases.forEach(([t, v, value, type], i) => {
      assert.equal(out[i].ok, true, `${t} ${JSON.stringify(v)}: ${out[i].error}`);
      assert.equal(out[i].value, value, `${t} ${JSON.stringify(v)}: value`);
      assert.equal(out[i].type, type, `${t} ${JSON.stringify(v)}: type`);
    });
    bad.forEach(([t, v, re], i) => {
      const o = out[cases.length + i];
      assert.equal(o.ok, false, `${t} ${JSON.stringify(v)} should fail`);
      assert.match(o.error, re);
    });
  });
});

describe('bridge.ps1 ConvertTo-BridgeValue for [object] parameters', { skip: !isWin && 'Windows PowerShell only' }, () => {
  // The conversion section of bridge.ps1 (class BridgeParamException .. ConvertTo-BridgeValue) is
  // self-contained; extract it so the functions can run without the stdin loop.
  function conversionSection() {
    const src = fs.readFileSync(BRIDGE, 'utf8');
    const start = src.indexOf('class BridgeParamException');
    const end = src.indexOf('function ConvertTo-Splat');
    assert.ok(start > 0 && end > start, 'bridge.ps1 layout changed: conversion section not found');
    return src.slice(start, end);
  }

  test('WriteVariable.Value ([object]) passes JSON string/number/bool/object through unchanged', () => {
    const script = `
$ErrorActionPreference = 'Stop'
${conversionSection()}
$meta = (Get-Command Write-TcVariable -ErrorAction SilentlyContinue)
$vals = ConvertFrom-Json -InputObject '{"items":["70.0", 70, 0.1, true, "T#5s", {"a":1}]}'
$res = @()
foreach ($v in $vals.items) {
  $x = ConvertTo-BridgeValue -TargetType ([object]) -Value $v -Name 'Value'
  $res += [PSCustomObject]@{ type = $x.GetType().Name; same = [object]::ReferenceEquals($x, $v) -or ($x -eq $v) }
}
[Console]::Out.Write(($res | ConvertTo-Json -Compress))
[Console]::Out.Write("\`n")
`;
    const out = runPs(script);
    // PS 5.1 ConvertFrom-Json: integers -> Int32, fractions -> Decimal (the cmdlet converts both)
    assert.deepEqual(out.map((o) => o.type), ['String', 'Int32', 'Decimal', 'Boolean', 'String', 'PSCustomObject']);
    assert.ok(out.every((o) => o.same === true), 'values must pass through untouched');
  });

  test('[object] parameters keep a JSON array an array, also with one or zero elements (Fields / Variables)', () => {
    const script = `
$ErrorActionPreference = 'Stop'
${conversionSection()}
$p = ConvertFrom-Json -InputObject '{"one":[{"name":"bReady","type":"BOOL"}],"two":[{"name":"a","type":"INT"},{"name":"b","type":"INT"}],"none":[]}'
$res = @()
foreach ($k in 'one', 'two', 'none') {
  $splat = @{}
  $splat['Fields'] = ConvertTo-BridgeValue -TargetType ([object]) -Value $p.$k -Name 'Fields'
  $x = $splat['Fields']
  $res += [PSCustomObject]@{ key = $k; isArray = ($x -is [System.Collections.IList]); count = @($x).Count; first = $(if (@($x).Count -gt 0) { @($x)[0].name } else { '' }) }
}
[Console]::Out.Write(($res | ConvertTo-Json -Compress))
[Console]::Out.Write("\`n")
`;
    const out = runPs(script);
    assert.deepEqual(out, [
      { key: 'one', isArray: true, count: 1, first: 'bReady' },
      { key: 'two', isArray: true, count: 2, first: 'a' },
      { key: 'none', isArray: true, count: 0, first: '' }
    ]);
  });

  test('numeric parameters still reject numeric strings (conversion belongs to the cmdlet, not the bridge)', () => {
    const script = `
$ErrorActionPreference = 'Stop'
${conversionSection()}
$res = @()
try { $null = ConvertTo-BridgeValue -TargetType ([int]) -Value '5' -Name 'IntervalMs'; $res += 'NO ERROR' } catch { $res += $_.Exception.Message }
$res += (ConvertTo-BridgeValue -TargetType ([int]) -Value 5 -Name 'IntervalMs').GetType().Name
[Console]::Out.Write(($res | ConvertTo-Json -Compress))
[Console]::Out.Write("\`n")
`;
    const out = runPs(script);
    assert.match(out[0], /expects a JSON number/);
    assert.equal(out[1], 'Int32');
  });
});

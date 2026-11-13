// Composite tools: orchestrate several bridge calls into one MCP tool.
// Each entry: { name, description, inputSchema, annotations, timeoutMs, run(ctx, args) }
//   ctx.bridge             PowerShellBridge
//   ctx.callTool(name, a)  runs a catalog tool through the normal path (validation + timeout) -> result object
//   ctx.lastIde            {ideProcessId, selectedBy, ownedBySession, solution, ideMainHwnd} of the last successful ConnectIde, or null
//   ctx.signal             AbortSignal of the MCP request (optional); forwarded to bridge calls
//   ctx.module             {modulePath, moduleCommit, moduleDirty, moduleSource, loadedAt} of the module the bridge has loaded (#41), or null
//   ctx.runtime            where this server runs from (#162: lib/runtime-info.js runtimeInfoOf + launcherPid, ownerIdFrom), or undefined
//   ctx.baseModulePath     module path the server was started with (TWINCAT_MODULE_PATH): the allow list of
//                          ReloadModule is derived from its checkout
//   ctx.onModuleReloaded(p) called after ReloadModule loaded module path p (index.js updates the probe scan script)
import { checkModulePath, pathKey } from './module-source.js';
import { MAX_CALL_TIMEOUT_MS } from './config.js';

function errorResult(code, message, hint) {
  const error = { code, message };
  if (hint) error.hint = hint;
  return { success: false, error };
}

const NOT_CONNECTED_CODES = new Set(['NOT_CONNECTED', 'ADS_NOT_CONNECTED']);

async function timed(name, fn) {
  const t0 = Date.now();
  let result;
  try {
    result = await fn();
  } catch (err) {
    result = errorResult('INTERNAL_ERROR', `${name} threw: ${err?.message ?? String(err)}`);
  }
  if (!result || typeof result !== 'object') {
    result = errorResult('INTERNAL_ERROR', `${name} returned no result object`);
  }
  return { name, success: result.success === true, durationMs: Date.now() - t0, result };
}

export const RunLifecycle = {
  name: 'RunLifecycle',
  description:
    'Full PLC lifecycle in one call: ConnectIde -> SetTarget (only with TargetAmsNetId or Platform) -> BuildProject (unless SkipBuild) -> EnableConfig (Force, waits for Run, logs in and downloads unless NoLogin) -> ConnectAds -> GetPlcState (readback). ' +
    'PowerShell equivalent: Start-TcLifecycle (same parameters, steps and data fields; #27). ' +
    'Pass TargetAmsNetId to select the UmRT/CX to activate on: a .tsproj without a saved target otherwise activates on the IDE default local runtime (ConnectIde data.amsNetId reports the target the IDE has). ' +
    'Platform is optional: EnableConfig compares the active solution platform with the platform the target reports through TARGETINFO (ADS port 200, IG 0x700) and switches + rebuilds on a mismatch. Runtimes that answer TARGETINFO with ADS 0x702 (e.g. the UmRT of TwinCAT 3.1.4026.21-22) report nothing: then pass Platform (e.g. "TwinCAT OS (x64)" for a Usermode Runtime / UmRT or TwinCAT/BSD, "TwinCAT RT (x64)" for a Windows RT target), which activates that solution platform in the SetTarget step before BuildProject (without TargetAmsNetId the AmsNetId reported by ConnectIde is used for it); without it a mismatch still ends in ACTIVATE_FAILED. Platform is also passed to EnableConfig (same value): it then finds the platforms equal and does not add the "-Platform was not given" warning (a platform the target reports through TARGETINFO still wins there); TargetAmsNetId without Platform calls SetTarget with NoPlatformSwitch=true (NetId only) and leaves the platform check to EnableConfig. ' +
    'Multi-PLC solutions: PlcProjectPath is passed to EnableConfig (only those PLCs are logged in and started), ExpectedProject to BuildProject (coverage check; not derived from PlcProjectPath), BuildTimeoutSec to BuildProject as TimeoutSec. ADS port of ConnectAds: AdsPort; without it the adsPort of EnableConfig data.plcs when they have exactly one distinct port (with or without PlcProjectPath); otherwise ConnectAds default 851. With PlcProjectPath and a non-empty data.plcs, an AdsPort that is not one of their adsPort values fails the ConnectAds step with PLC_PORT_MISMATCH (allowed ports in the message, nothing connected; EnableConfig already activated and, without NoLogin, logged in / Run). Example: PlcProjectPath ["FrameworkUnitTest"], ExpectedProject ["FrameworkUnitTest"], AdsPort 852. ' +
    'Readback: without NoLogin the GetPlcState state must be Run, otherwise RUNTIME_STATE_MISMATCH; with NoLogin it is only reported. ' +
    'Changes the running machine (TwinCAT restarts, PLC program is downloaded and started); confirm with the user first. ' +
    'Fail closed (#68): while the target has a lifecycle block (an earlier SetSystemState / EnableConfig / SetPlcState sent a runtime-changing request and then failed) the EnableConfig step returns LIFECYCLE_BLOCKED (ConnectIde / SetTarget / BuildProject before it still run): stop, report the error and data.steps to the user, never retry through another control channel, and call ClearLifecycleBlock only after the user agreed. ' +
    'Stops at the first failing step; error is that step\'s error as it is. Error codes, data fields and the meaning of hints match Start-TcLifecycle; hint wording is not guaranteed to be identical (the LIBRARY_UNRESOLVED hint addition below is MCP only). data: steps[] ({name, success, code (error code of a failed step, else null), durationMs, result (raw step result)}), failedStep (null on success), plcProjects (EnableConfig data.plcs), adsPort (ConnectAds data.port), loggedIn (EnableConfig data.loggedIn), plcState (GetPlcState data.state), lifecycleBlock (the failed step\'s data.lifecycleBlock); fields of steps that did not run are null. ' +
    'A project with unresolved libraries stops at BuildProject with LIBRARY_UNRESOLVED (the PLC code may not have been compiled): install the libraries first. There is no AllowUnresolvedLibrary here (#61): code whose build did not prove it compiled (codeVerified not true) is not activated, downloaded or started once the module recorded that build (known limits: BUILD_REQUIRED in docs/troubleshooting.md), so even after BuildProject AllowUnresolvedLibrary=true RunLifecycle SkipBuild=true stops at EnableConfig with BUILD_REQUIRED.',
  annotations: { destructiveHint: true, readOnlyHint: false },
  // Informational upper bound (a composite is not cut off by it: every step has its own catalog
  // timeout). The sum of the step maxima (BuildTimeoutSec 7200 s + grace, EnableConfig TimeoutSec
  // 3600 s + grace, plus ConnectIde / SetTarget / ConnectAds / GetPlcState) is above
  // MAX_CALL_TIMEOUT_MS (2 h), so it is capped there.
  timeoutMs: MAX_CALL_TIMEOUT_MS,
  inputSchema: {
    type: 'object',
    properties: {
      SolutionPath: { type: 'string', description: 'Solution (.sln) to open on ConnectIde. Given or omitted, only an IDE TcAuto launched or one already bound with ConnectIde ProcessId (user consent) is attached - with it, an IDE that already has the .sln open (#281 C); else IDE_ATTACH_CONSENT_REQUIRED (ask the user, then ConnectIde ProcessId=<pid>, plus SolutionPath when given).' },
      ProgId: { type: 'string', description: 'Visual Studio / XAE shell ProgId passed to ConnectIde.' },
      NoLaunch: { type: 'boolean', description: 'Do not launch XAE if it is not running.' },
      TargetAmsNetId: { type: 'string', description: 'AmsNetId to select with SetTarget after ConnectIde and before BuildProject/EnableConfig (e.g. the UmRT or CX you want to activate on). Omit to keep the target the IDE/solution already has (reported as ConnectIde data.amsNetId).' },
      Platform: { type: 'string', description: 'Optional solution platform passed to SetTarget and EnableConfig (e.g. "TwinCAT OS (x64)" for a Usermode Runtime / UmRT or TwinCAT/BSD, "TwinCAT RT (x64)" for a Windows RT target). Needed only when the target does not report its platform (TARGETINFO, ADS 0x702); omit it and EnableConfig follows the platform the target reports.' },
      SkipBuild: { type: 'boolean', description: 'Skip BuildProject (default false). After a solution platform switch EnableConfig still refuses to activate (BUILD_REQUIRED) until a complete BuildProject (data.completeBuild=true).' },
      TimeoutSec: { type: 'integer', minimum: 10, maximum: 3600, description: 'EnableConfig timeout in seconds (default 120, 10..3600).' },
      NoLogin: { type: 'boolean', description: 'EnableConfig: activate only, skip PLC login/download/Run. The GetPlcState readback then only reports the state.' },
      PlcProjectPath: { type: 'array', items: { type: 'string' }, minItems: 1, description: 'EnableConfig PlcProjectPath: PLC project(s) to log into and start (name, e.g. "FrameworkUnitTest", or tree path). Default: every enabled PLC project.' },
      ExpectedProject: { type: 'array', items: { type: 'string' }, minItems: 1, description: 'BuildProject ExpectedProject: PLC project(s) that must be part of the build (PROJECT_SKIPPED_BY_CONFIGURATION / EXPECTED_PROJECT_NOT_FOUND otherwise). Not derived from PlcProjectPath.' },
      AdsPort: { type: 'integer', minimum: 1, maximum: 65535, description: 'ADS port for ConnectAds. Default: the one distinct adsPort of EnableConfig data.plcs, else 851. With PlcProjectPath it must be the port of a selected PLC, else PLC_PORT_MISMATCH.' },
      BuildTimeoutSec: { type: 'integer', minimum: 5, maximum: 7200, description: 'BuildProject TimeoutSec (5..7200). Default: the BuildProject default.' }
    },
    required: [],
    additionalProperties: false
  },
  async run(ctx, args = {}) {
    const steps = [];
    const data = { steps, failedStep: null, plcProjects: null, adsPort: null, loggedIn: null, plcState: null, lifecycleBlock: null };
    // same key order as Start-TcLifecycle: name, success, code, durationMs, result
    const add = (step) => {
      const out = {
        name: step.name,
        success: step.success,
        code: step.success ? null : (step.result?.error?.code ?? 'STEP_FAILED'),
        durationMs: step.durationMs,
        result: step.result
      };
      steps.push(out);
      return out;
    };
    // error = the step's error as it is (LIFECYCLE_BLOCKED included); errorOverride for a step that
    // ran but failed its postcondition (RUNTIME_STATE_MISMATCH: result stays the raw GetPlcState result)
    const fail = (step, errorOverride) => {
      data.failedStep = step.name;
      const block = step.result?.data?.lifecycleBlock;
      if (block !== undefined) data.lifecycleBlock = block;
      return {
        success: false,
        data,
        error: errorOverride ?? step.result?.error ?? errorResult('STEP_FAILED', `${step.name} failed`).error
      };
    };

    const connectArgs = {};
    if (args.SolutionPath !== undefined) connectArgs.SolutionPath = args.SolutionPath;
    if (args.ProgId !== undefined) connectArgs.ProgId = args.ProgId;
    if (args.NoLaunch !== undefined) connectArgs.NoLaunch = args.NoLaunch;

    let step = add(await timed('ConnectIde', () => ctx.callTool('ConnectIde', connectArgs)));
    if (!step.success) return fail(step);

    const hasTarget = typeof args.TargetAmsNetId === 'string' && args.TargetAmsNetId !== '';
    const hasPlatform = typeof args.Platform === 'string' && args.Platform !== '';
    if (hasTarget || hasPlatform) {
      // SetTarget needs an AmsNetId: without TargetAmsNetId keep the target ConnectIde reported.
      const amsNetId = hasTarget ? args.TargetAmsNetId : step.result?.data?.amsNetId;
      if (typeof amsNetId !== 'string' || amsNetId === '') {
        step = add({
          name: 'SetTarget',
          success: false,
          durationMs: 0,
          result: errorResult('AMS_NETID_REQUIRED', 'Platform was given without TargetAmsNetId and ConnectIde reported no target AmsNetId.', 'Pass TargetAmsNetId together with Platform.')
        });
        return fail(step);
      }
      const setArgs = { AmsNetId: amsNetId };
      // Without Platform only the NetId is set: SetTarget would otherwise return PLATFORM_UNKNOWN on
      // runtimes without TARGETINFO; EnableConfig does the platform check (target or skipped + warning).
      if (hasPlatform) setArgs.Platform = args.Platform;
      else setArgs.NoPlatformSwitch = true;
      step = add(await timed('SetTarget', () => ctx.callTool('SetTarget', setArgs)));
      if (!step.success) return fail(step);
    }

    if (!args.SkipBuild) {
      const buildArgs = {};
      if (args.ExpectedProject !== undefined) buildArgs.ExpectedProject = args.ExpectedProject;
      if (args.BuildTimeoutSec !== undefined) buildArgs.TimeoutSec = args.BuildTimeoutSec;
      step = add(await timed('BuildProject', () => ctx.callTool('BuildProject', buildArgs)));
      if (!step.success) {
        const out = fail(step);
        if (out.error?.code === 'LIBRARY_UNRESOLVED') {
          const extra = 'RunLifecycle: install the missing libraries (XAE Library Manager) and run it again; a build with unresolved libraries is never activated (#61).';
          out.error = { ...out.error, hint: out.error.hint ? `${out.error.hint} ${extra}` : extra };
        }
        return out;
      }
    }

    const enableArgs = { Force: true, TimeoutSec: args.TimeoutSec ?? 120 };
    if (args.NoLogin !== undefined) enableArgs.NoLogin = args.NoLogin;
    // Same Platform as SetTarget: without it EnableConfig skips its platform check on runtimes
    // without TARGETINFO and returns the long "-Platform was not given" data.warning (task 1.8).
    if (hasPlatform) enableArgs.Platform = args.Platform;
    const plcPaths = Array.isArray(args.PlcProjectPath) ? args.PlcProjectPath.filter((p) => typeof p === 'string' && p.trim() !== '') : [];
    if (plcPaths.length > 0) enableArgs.PlcProjectPath = args.PlcProjectPath;
    step = add(await timed('EnableConfig', () => ctx.callTool('EnableConfig', enableArgs)));
    const ed = step.result?.data;
    if (ed && typeof ed === 'object') {
      if (ed.plcs !== undefined) data.plcProjects = ed.plcs === null ? null : [].concat(ed.plcs);
      if (ed.loggedIn !== undefined) data.loggedIn = ed.loggedIn;
    }
    if (!step.success) return fail(step);

    // ConnectAds port. Distinct adsPort values of EnableConfig data.plcs (a PLC named twice in
    // PlcProjectPath counts once). AdsPort: with PlcProjectPath and a non-empty data.plcs it must be
    // one of them (PLC_PORT_MISMATCH otherwise). Without AdsPort: the port when there is exactly one,
    // else no Port (ConnectAds default 851).
    const plcList = Array.isArray(data.plcProjects) ? data.plcProjects.filter((p) => p && p.adsPort !== undefined && p.adsPort !== null) : [];
    const plcPorts = [...new Set(plcList.map((p) => Number(p.adsPort)))].sort((a, b) => a - b);
    const adsArgs = {};
    if (args.AdsPort !== undefined) {
      if (plcPaths.length > 0 && plcPorts.length > 0 && !plcPorts.includes(args.AdsPort)) {
        const names = [...new Set(plcList.map((p) => `${p.name}:${Number(p.adsPort)}`))].sort().join(', ');
        step = add({
          name: 'ConnectAds',
          success: false,
          durationMs: 0,
          result: {
            ...errorResult(
              'PLC_PORT_MISMATCH',
              `AdsPort ${args.AdsPort} is not the ADS port of a PLC project selected with PlcProjectPath (allowed: ${plcPorts.join(', ')}; ${names}); ADS was not connected.`,
              'AdsPort is not the ADS port of a PLC selected with PlcProjectPath (allowed ports in error.message; ConnectAds step result.data allowedPorts / plcs); ADS was not connected. EnableConfig already succeeded: activated; without NoLogin also logged in / Run. No need to rerun the lifecycle: ConnectAds Port=<one of allowedPorts>, then GetPlcState (PowerShell: Connect-TcAds -Port, Get-TcPlcState); next time drop AdsPort or pass an allowed port.'
            ),
            data: {
              adsPort: args.AdsPort,
              allowedPorts: plcPorts,
              plcs: plcList.map((p) => ({ name: p.name ?? null, projectPath: p.projectPath ?? null, adsPort: Number(p.adsPort) }))
            }
          }
        });
        return fail(step);
      }
      adsArgs.Port = args.AdsPort;
    } else if (plcPorts.length === 1) {
      adsArgs.Port = plcPorts[0];
    }
    step = add(await timed('ConnectAds', () => ctx.callTool('ConnectAds', adsArgs)));
    if (step.result?.data && step.result.data.port !== undefined) data.adsPort = step.result.data.port;
    if (!step.success) return fail(step);

    // Readback (CODING_STANDARDS 2): success only after the PLC state was read
    step = add(await timed('GetPlcState', () => ctx.callTool('GetPlcState', {})));
    if (step.result?.data && step.result.data.state !== undefined) data.plcState = step.result.data.state;
    if (!step.success) return fail(step);
    if (!args.NoLogin && data.plcState !== 'Run') {
      step.success = false;
      step.code = 'RUNTIME_STATE_MISMATCH';
      return fail(
        step,
        errorResult(
          'RUNTIME_STATE_MISMATCH',
          `PLC state on ADS port ${data.adsPort} is '${data.plcState}' after EnableConfig Force=true, expected 'Run'.`,
          'Report data.steps to the user; do not retry through another channel. Check the EnableConfig step result (data.finalCheck, data.plcs) and GetIdeModalDialog; with several PLC projects pass PlcProjectPath / AdsPort for the PLC you need.'
        ).error
      );
    }

    return { success: true, data };
  }
};

export const QuickRead = {
  name: 'QuickRead',
  description:
    'Read one or more PLC variables, connecting ADS on demand: calls ReadVariable and, if ADS is not connected yet, runs ConnectAds (AmsNetId/Port optional, auto-detected from the IDE target) and reads again. ' +
    'Returns the ReadVariable result plus connectedOnDemand (whether a connection was made): always at the top level of the result, and also as data.connectedOnDemand when data is an object (one Path). With several paths data stays the array of per-path entries (each {path, value, type} or {path, error, code}); ' +
    'fail closed (#60): when any of several paths fails the result is success=false with PARTIAL_READ_FAILED, data still holds every entry, and the top level has partial=true and failedPaths (the failed paths in input order); every path read: success=true, partial=false, failedPaths=[].',
  annotations: { readOnlyHint: true },
  timeoutMs: 120000,
  inputSchema: {
    type: 'object',
    properties: {
      Path: { type: 'array', items: { type: 'string' }, minItems: 1, description: 'Symbol paths, e.g. ["MAIN.nCounter"].' },
      AmsNetId: { type: 'string', description: 'AmsNetId for ConnectAds when not connected (default: auto-detect).' },
      Port: { type: 'integer', description: 'ADS port for ConnectAds when not connected (default 851).' }
    },
    required: ['Path'],
    additionalProperties: false
  },
  async run(ctx, args) {
    const readArgs = { Path: args.Path };
    // #57: an array data (several paths) must stay an array; spreading it into an object would
    // turn the entries into "0"/"1" keys. connectedOnDemand goes to the top level in every case.
    // Same rule as stampOrder in bridge.js: only a missing data is created, null stays null.
    const decorate = (result, connectedOnDemand) => {
      const out = { ...result, connectedOnDemand };
      const d = result.data;
      if (d === undefined) out.data = { connectedOnDemand };
      else if (d !== null && typeof d === 'object' && !Array.isArray(d)) out.data = { ...d, connectedOnDemand };
      return out;
    };

    let result = await ctx.callTool('ReadVariable', readArgs);
    if (result.success === true || !NOT_CONNECTED_CODES.has(result.error?.code)) {
      return decorate(result, false);
    }

    const connectArgs = {};
    if (args.AmsNetId !== undefined) connectArgs.AmsNetId = args.AmsNetId;
    if (args.Port !== undefined) connectArgs.Port = args.Port;
    const connect = await ctx.callTool('ConnectAds', connectArgs);
    if (connect.success !== true) {
      return decorate({ success: false, error: connect.error ?? errorResult('ADS_CONNECT_FAILED', 'ConnectAds failed').error, data: { connect } }, false);
    }
    result = await ctx.callTool('ReadVariable', readArgs);
    return decorate(result, true);
  }
};

export const GetStatus = {
  name: 'GetStatus',
  description:
    'Snapshot of the whole stack: bridge state (IDE/ADS connected, AmsNetId), IDE info, TwinCAT system state and PLC state. ' +
    'data.bridge also names the loaded PowerShell module: modulePath, moduleCommit, moduleDirty, moduleSource and loadedAt (ISO time the bridge reported ready; changes after a bridge restart or ReloadModule). moduleSource "git-checkout": moduleCommit is the 40-character git sha HEAD of that checkout pointed at when the module was loaded, read from the .git files, and moduleDirty is null (uncommitted changes in the working tree cannot be known without running git); moduleSource "installed" (#162, a runtime installed by scripts/Install-TcAutoRuntime.ps1): moduleCommit and moduleDirty come from its tcauto-source.json; any other path: all three are null. ' +
    'data.bridge.runtime says where the MCP server itself runs from (#162): source ("installed" | "git-checkout" | "unknown"), runtimeDir, runtimeRoot (install root of an installed runtime), version, commit, branch, dirty, installedAt, sourcePath, launcherPid (set when the launcher started it: switch versions with ReloadRuntime) and ownerIdFrom ("launcher" | "server"). ' +
    'Fails with NOT_CONNECTED when the IDE is not connected (run ConnectIde first); each sub-query is independent, a failing one is reported in place without aborting the others.',
  annotations: { readOnlyHint: true },
  timeoutMs: 120000,
  inputSchema: {
    type: 'object',
    properties: {
      AmsNetId: { type: 'string', description: 'Target for GetSystemState (default: the AmsNetId the bridge already knows).' }
    },
    required: [],
    additionalProperties: false
  },
  async run(ctx, args = {}) {
    const stateResult = await ctx.bridge.call('state', { signal: ctx.signal });
    if (stateResult.success !== true) return stateResult;
    // #41: which module the bridge runs (path, commit read from the .git files at load time, load time)
    const mod = ctx.module ?? {};
    const state = {
      ...(stateResult.data ?? {}),
      modulePath: mod.modulePath ?? null,
      moduleCommit: mod.moduleCommit ?? null,
      moduleDirty: mod.moduleDirty ?? null,
      moduleSource: mod.moduleSource ?? null,
      loadedAt: mod.loadedAt ?? null,
      runtime: ctx.runtime ?? null
    };

    if (!state.ideConnected) {
      return {
        success: false,
        error: { code: 'NOT_CONNECTED', message: 'IDE not connected', hint: 'Run ConnectIde first (optionally with SolutionPath).' },
        data: { bridge: state }
      };
    }

    const attempt = async (name, toolArgs) => {
      try {
        return await ctx.callTool(name, toolArgs);
      } catch (err) {
        return errorResult('INTERNAL_ERROR', `${name} threw: ${err?.message ?? String(err)}`);
      }
    };

    const ide = await attempt('GetIdeInfo', {});
    const systemArgs = {};
    const amsNetId = args.AmsNetId ?? state.amsNetId ?? undefined;
    if (amsNetId !== undefined && amsNetId !== null) systemArgs.AmsNetId = amsNetId;
    const system = await attempt('GetSystemState', systemArgs);
    const plc = state.adsConnected ? await attempt('GetPlcState', {}) : null;

    return { success: true, data: { bridge: state, ide, system, plc } };
  }
};

export const GetIdeModalDialog = {
  name: 'GetIdeModalDialog',
  description:
    'Check whether the XAE (Visual Studio shell) window is blocked by a modal dialog, e.g. "Assertion Failed" or a license prompt. ' +
    'Use it before BuildProject / EnableConfig when the IDE seems stuck, and after a BRIDGE_TIMEOUT. Needs an IDE process id: the one from ConnectIde, ' +
    'or (after a bridge restart) the last ConnectIde this server saw, or an explicit ProcessId. ' +
    'Returns data.scanComplete = true and data.dialog = null when nothing is blocking, otherwise {title, text, kind, reloadTarget, hwnd, buttons}. ' +
    'A scan that did not finish within TimeoutSec is NOT "no dialog": success false, code MODAL_SCAN_INCOMPLETE, data.scanComplete = false, ' +
    'data.modalScan.reason (timeout | prepare-timeout | error); retry with a larger TimeoutSec (e.g. 15). kind "reload-prompt" is ' +
    'either the VS prompt "File has been changed outside the environment. Reload the new file?" (reloadTarget "file": a file open in an XAE ' +
    'editor was changed on disk) or the XAE prompt "The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the ' +
    'project?" (reloadTarget "project": a .plcproj was rewritten on disk). For both call ResetSolution: it answers Yes to the project prompt ' +
    '(XAE reloads the project, no close / reopen) and dismisses the file prompt, closes all documents and reopens the solution. ' +
    'Any other dialog is kind "unknown" (reloadTarget null): handle it by hand, or DisconnectIde Quit=true Kill=true for an IDE ConnectIde launched. ' +
    'buttons = [{id, name}] of a Win32 message box (control id 1 OK, 2 Cancel, 6 Yes, 7 No; name is the localized caption).',
  annotations: { readOnlyHint: true },
  // bridge.ps1 Invoke-OpModal caps the scan preparation so that preparation + TimeoutSec + 15 s
  // margin stays below this (#42): change both together.
  timeoutMs: 90000,
  inputSchema: {
    type: 'object',
    properties: {
      TimeoutSec: { type: 'integer', minimum: 1, maximum: 60, description: 'How long to probe for a dialog (default 5).' },
      ProcessId: { type: 'integer', minimum: 1, description: 'IDE process id to probe instead of the one the bridge knows (e.g. data.lastIde.ideProcessId after BRIDGE_TIMEOUT).' }
    },
    required: [],
    additionalProperties: false
  },
  async run(ctx, args = {}) {
    const params = {};
    if (args.TimeoutSec !== undefined) params.TimeoutSec = args.TimeoutSec;
    if (args.ProcessId !== undefined) {
      params.ProcessId = args.ProcessId;
    } else {
      // After a BRIDGE_TIMEOUT / BRIDGE_DIED the restarted bridge has no IDE pid, but the server still
      // remembers the last ConnectIde (ctx.lastIde): use it so the dialog can be inspected without
      // reconnecting first. 'state' makes no COM calls.
      const state = await ctx.bridge.call('state', { signal: ctx.signal });
      const bridgePid = state.success === true ? state.data?.ideProcessId : null;
      const fallback = ctx.lastIde?.ideProcessId;
      if (!(Number.isInteger(bridgePid) && bridgePid > 0) && Number.isInteger(fallback) && fallback > 0) params.ProcessId = fallback;
    }
    return ctx.bridge.call('modal', { params, timeoutMs: this.timeoutMs, signal: ctx.signal });
  }
};

function moduleSnapshot(m) {
  // moduleDirty: null for a git checkout (uncommitted changes cannot be read from the .git files
  // without running git, #41 review); an installed runtime (#162) has it in its tcauto-source.json.
  return {
    modulePath: m?.modulePath ?? null,
    moduleCommit: m?.moduleCommit ?? null,
    moduleDirty: m?.moduleDirty ?? null,
    moduleSource: m?.moduleSource ?? null,
    loadedAt: m?.loadedAt ?? null
  };
}

export const ReloadModule = {
  name: 'ReloadModule',
  description:
    'Load the TwinCATAutomation PowerShell module again (#41): the bridge process is retired and a new one imports the module from ModulePath (omit it to reload the module path loaded now). ' +
    "ModulePath must be src\\TwinCATAutomation\\TwinCATAutomation.psm1 of the main checkout the server was started from, or the same file in one of that repository's git worktrees (the entries of `git worktree list`); any other path is refused with RELOAD_PATH_NOT_ALLOWED (data.allowed lists the accepted paths). " +
    'Fail closed (#68): while the loaded module holds a lifecycle block in memory the reload is refused with RELOAD_LIFECYCLE_BLOCKED and nothing changes; report data.lifecycleBlocks to the user, ClearLifecycleBlock only after the user agreed. ' +
    'BUILD_REQUIRED entries the module holds in memory are written to build-required.json first (data.buildRequiredPersisted lists the ones that were missing there); when that file cannot be read or written the reload is refused with RELOAD_BUILD_REQUIRED and nothing changes. ' +
    'The IDE and ADS connections are released first (DisconnectIde without Quit: the IDE keeps running; DisconnectAds): run ConnectIde (and ConnectAds) again after the reload. ' +
    'Returns data.previous and data.current = {modulePath, moduleCommit, moduleDirty, moduleSource, loadedAt} (as GetStatus data.bridge: in a git checkout moduleCommit is the 40-character git sha HEAD pointed at, read from the .git files, and moduleDirty is null because uncommitted working-tree changes are not reflected). A new module that fails to import returns RELOAD_FAILED; the previous module path is then started again (data.restored). ' +
    'Only the PowerShell module is reloaded: the MCP server (index.js, bridge.ps1) and its tool list (tools.json) stay those of the running server; a cmdlet or parameter the new module adds is not offered until the server restarts. ' +
    'Installed runtime (#162, GetStatus data.bridge.runtime.source "installed"): only the loaded module can be reloaded (omit ModulePath); to switch to another version run scripts/Install-TcAutoRuntime.ps1 in the checkout, then ReloadRuntime (a tool of the launcher): it replaces the whole runtime (index.js, bridge.ps1, tools.json and the module) and refreshes the tool list.',
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
  timeoutMs: 210000, // retire 90 s + start 60 s + restore start 60 s
  inputSchema: {
    type: 'object',
    properties: {
      ModulePath: {
        type: 'string',
        description:
          'Absolute path of TwinCATAutomation.psm1 to load: <main checkout>\\src\\TwinCATAutomation\\TwinCATAutomation.psm1 or the same relative path in a git worktree of that repository. Omit to reload the module path loaded now.'
      }
    },
    required: [],
    additionalProperties: false
  },
  async run(ctx, args = {}) {
    const bridge = ctx.bridge;
    const previous = moduleSnapshot(ctx.module);
    const previousPath = bridge.modulePath;
    let target = previousPath;
    if (args.ModulePath !== undefined) {
      const check = checkModulePath(args.ModulePath, ctx.baseModulePath);
      if (!check.ok) {
        return {
          success: false,
          error: {
            code: 'RELOAD_PATH_NOT_ALLOWED',
            message: `ReloadModule NOT RUN: ${check.reason} (${args.ModulePath}). Nothing was disconnected or reloaded.`,
            hint: 'Pass the TwinCATAutomation.psm1 of the main checkout or of one of its git worktrees (data.allowed), or omit ModulePath to reload the current module.'
          },
          data: { requested: args.ModulePath, allowed: check.allowed, previous, notRun: true }
        };
      }
      target = check.path;
    }

    const retire = await bridge.retire(target, { timeoutMs: 90000, signal: ctx.signal });
    if (retire.success !== true) {
      // RELOAD_LIFECYCLE_BLOCKED (nothing changed), CANCELLED, BRIDGE_* or MODULE_IMPORT_FAILED of the old module
      const extra = retire.data && typeof retire.data === 'object' && !Array.isArray(retire.data) ? retire.data : {};
      return { ...retire, data: { ...extra, requested: target, previous } };
    }

    let started = null;
    let startError = null;
    try {
      started = await bridge.start();
    } catch (err) {
      startError = { code: err?.code ?? 'MODULE_IMPORT_FAILED', message: err?.message ?? String(err) };
    }
    if (startError) {
      // Bring the previous module back so the server stays usable; the IDE/ADS state is gone either way.
      let restored = false;
      let restoreError = null;
      const back = previousPath;
      if (back && pathKey(back) !== pathKey(target)) {
        bridge.modulePath = back;
        try {
          await bridge.start();
          restored = true;
          ctx.onModuleReloaded?.(back);
        } catch (err) {
          restoreError = err?.message ?? String(err);
        }
      }
      return {
        success: false,
        error: {
          code: 'RELOAD_FAILED',
          message: `ReloadModule: the bridge was retired but ${target} could not be imported (${startError.code}: ${startError.message}).`,
          hint: restored
            ? 'The previous module was loaded again (data.current). Fix the module (Import-Module -Force in a Windows PowerShell 5.1 console shows the error), then ReloadModule again. Run ConnectIde again either way.'
            : 'No module is loaded now: every call returns MODULE_IMPORT_FAILED until a ReloadModule with a module that imports succeeds or the server restarts.'
        },
        data: { requested: target, previous, current: restored ? moduleSnapshot(ctx.module) : null, restored, restoreError, importError: startError, retired: retire.data ?? null }
      };
    }

    ctx.onModuleReloaded?.(target);
    const was = retire.data ?? {};
    return {
      success: true,
      data: {
        previous,
        current: moduleSnapshot(ctx.module),
        cmdlets: Array.isArray(started?.cmdlets) ? started.cmdlets.length : null,
        ideDisconnected: was.ideWasConnected === true,
        adsDisconnected: was.adsWasConnected === true,
        buildRequiredPersisted: Array.isArray(was.buildRequiredPersisted) ? was.buildRequiredPersisted : [],
        reconnectRequired: true,
        note: 'The IDE and ADS connections were released before the reload (the IDE keeps running). Run ConnectIde again (and ConnectAds) before any IDE or ADS tool.'
      }
    };
  }
};

export const composites = [RunLifecycle, QuickRead, GetStatus, GetIdeModalDialog, ReloadModule];
export default composites;

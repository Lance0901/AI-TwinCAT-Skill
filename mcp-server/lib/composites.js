// Composite tools: orchestrate several bridge calls into one MCP tool.
// Each entry: { name, description, inputSchema, annotations, timeoutMs, run(ctx, args) }
//   ctx.bridge             PowerShellBridge
//   ctx.callTool(name, a)  runs a catalog tool through the normal path (validation + timeout) -> result object
//   ctx.lastIde            {ideProcessId, selectedBy, solution, ideMainHwnd} of the last successful ConnectIde, or null
//   ctx.signal             AbortSignal of the MCP request (optional); forwarded to bridge calls

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
    'Full PLC lifecycle in one call: ConnectIde -> SetTarget (only with TargetAmsNetId or Platform) -> BuildProject (unless SkipBuild) -> EnableConfig (Force, waits for Run, logs in and downloads unless NoLogin) -> ConnectAds. ' +
    'Pass TargetAmsNetId to select the UmRT/CX to activate on: a .tsproj without a saved target otherwise activates on the IDE default local runtime (ConnectIde data.amsNetId reports the target the IDE has). ' +
    'Platform is optional: EnableConfig compares the active solution platform with the platform the target reports through TARGETINFO (ADS port 200, IG 0x700) and switches + rebuilds on a mismatch. Runtimes that answer TARGETINFO with ADS 0x702 (e.g. the UmRT of TwinCAT 3.1.4026.21-22) report nothing: then pass Platform (e.g. "TwinCAT OS (x64)" for a Usermode Runtime / UmRT or TwinCAT/BSD, "TwinCAT RT (x64)" for a Windows RT target), which activates that solution platform in the SetTarget step before BuildProject (without TargetAmsNetId the AmsNetId reported by ConnectIde is used for it); without it a mismatch still ends in ACTIVATE_FAILED. Platform is given to SetTarget only (EnableConfig then finds the platforms equal); TargetAmsNetId without Platform calls SetTarget with NoPlatformSwitch=true (NetId only) and leaves the platform check to EnableConfig. ' +
    'Changes the running machine (TwinCAT restarts, PLC program is downloaded and started); confirm with the user first. ' +
    'Stops at the first failing step; data.steps lists every step that ran with its duration and raw result, data.failedStep names the failure and error is that step\'s error. ' +
    'A project with unresolved libraries stops at BuildProject with LIBRARY_UNRESOLVED (the PLC code may not have been compiled): install the libraries, or, when the user accepts that, pass AllowUnresolvedLibrary=true (or run BuildProject AllowUnresolvedLibrary=true first and then RunLifecycle SkipBuild=true).',
  annotations: { destructiveHint: true, readOnlyHint: false },
  timeoutMs: 1500000,
  inputSchema: {
    type: 'object',
    properties: {
      SolutionPath: { type: 'string', description: 'Solution (.sln) to open on ConnectIde. Omit to attach to the running XAE.' },
      ProgId: { type: 'string', description: 'Visual Studio / XAE shell ProgId passed to ConnectIde.' },
      NoLaunch: { type: 'boolean', description: 'Do not launch XAE if it is not running.' },
      TargetAmsNetId: { type: 'string', description: 'AmsNetId to select with SetTarget after ConnectIde and before BuildProject/EnableConfig (e.g. the UmRT or CX you want to activate on). Omit to keep the target the IDE/solution already has (reported as ConnectIde data.amsNetId).' },
      Platform: { type: 'string', description: 'Optional solution platform passed to SetTarget (e.g. "TwinCAT OS (x64)" for a Usermode Runtime / UmRT or TwinCAT/BSD, "TwinCAT RT (x64)" for a Windows RT target). Needed only when the target does not report its platform (TARGETINFO, ADS 0x702); omit it and EnableConfig follows the platform the target reports.' },
      SkipBuild: { type: 'boolean', description: 'Skip BuildProject (default false). After a solution platform switch EnableConfig still refuses to activate (BUILD_REQUIRED) until a BuildProject has succeeded.' },
      AllowUnresolvedLibrary: { type: 'boolean', description: 'Passed to BuildProject and EnableConfig: accept a build whose Error List shows unresolved libraries (LIBRARY_UNRESOLVED) as success. Only when the user accepts that the PLC code may not have been compiled.' },
      TimeoutSec: { type: 'integer', minimum: 10, maximum: 3600, description: 'EnableConfig timeout in seconds (default 120, 10..3600).' },
      NoLogin: { type: 'boolean', description: 'EnableConfig: activate only, skip PLC login/download/Run.' }
    },
    required: [],
    additionalProperties: false
  },
  async run(ctx, args = {}) {
    const steps = [];
    const fail = (step) => ({
      success: false,
      data: { steps, failedStep: step.name },
      error: step.result.error ?? errorResult('STEP_FAILED', `${step.name} failed`).error
    });

    const connectArgs = {};
    if (args.SolutionPath !== undefined) connectArgs.SolutionPath = args.SolutionPath;
    if (args.ProgId !== undefined) connectArgs.ProgId = args.ProgId;
    if (args.NoLaunch !== undefined) connectArgs.NoLaunch = args.NoLaunch;

    let step = await timed('ConnectIde', () => ctx.callTool('ConnectIde', connectArgs));
    steps.push(step);
    if (!step.success) return fail(step);

    const hasTarget = typeof args.TargetAmsNetId === 'string' && args.TargetAmsNetId !== '';
    const hasPlatform = typeof args.Platform === 'string' && args.Platform !== '';
    if (hasTarget || hasPlatform) {
      // SetTarget needs an AmsNetId: without TargetAmsNetId keep the target ConnectIde reported.
      const amsNetId = hasTarget ? args.TargetAmsNetId : step.result?.data?.amsNetId;
      if (typeof amsNetId !== 'string' || amsNetId === '') {
        step = {
          name: 'SetTarget',
          success: false,
          durationMs: 0,
          result: errorResult('AMS_NETID_REQUIRED', 'Platform was given without TargetAmsNetId and ConnectIde reported no target AmsNetId.', 'Pass TargetAmsNetId together with Platform.')
        };
        steps.push(step);
        return fail(step);
      }
      const setArgs = { AmsNetId: amsNetId };
      // Without Platform only the NetId is set: SetTarget would otherwise return PLATFORM_UNKNOWN on
      // runtimes without TARGETINFO; EnableConfig does the platform check (target or skipped + warning).
      if (hasPlatform) setArgs.Platform = args.Platform;
      else setArgs.NoPlatformSwitch = true;
      step = await timed('SetTarget', () => ctx.callTool('SetTarget', setArgs));
      steps.push(step);
      if (!step.success) return fail(step);
    }

    if (!args.SkipBuild) {
      const buildArgs = args.AllowUnresolvedLibrary ? { AllowUnresolvedLibrary: true } : {};
      step = await timed('BuildProject', () => ctx.callTool('BuildProject', buildArgs));
      steps.push(step);
      if (!step.success) {
        const out = fail(step);
        if (out.error?.code === 'LIBRARY_UNRESOLVED') {
          const extra = 'RunLifecycle: install the missing libraries, or (only when the user accepts that the code may not have been compiled) RunLifecycle AllowUnresolvedLibrary=true, or BuildProject AllowUnresolvedLibrary=true and then RunLifecycle SkipBuild=true.';
          out.error = { ...out.error, hint: out.error.hint ? `${out.error.hint} ${extra}` : extra };
        }
        return out;
      }
    }

    const enableArgs = { Force: true, TimeoutSec: args.TimeoutSec ?? 120 };
    if (args.NoLogin !== undefined) enableArgs.NoLogin = args.NoLogin;
    if (args.AllowUnresolvedLibrary) enableArgs.AllowUnresolvedLibrary = true;
    step = await timed('EnableConfig', () => ctx.callTool('EnableConfig', enableArgs));
    steps.push(step);
    if (!step.success) return fail(step);

    step = await timed('ConnectAds', () => ctx.callTool('ConnectAds', {}));
    steps.push(step);
    if (!step.success) return fail(step);

    return { success: true, data: { steps } };
  }
};

export const QuickRead = {
  name: 'QuickRead',
  description:
    'Read one or more PLC variables, connecting ADS on demand: calls ReadVariable and, if ADS is not connected yet, runs ConnectAds (AmsNetId/Port optional, auto-detected from the IDE target) and reads again. ' +
    'Returns the ReadVariable result with data.connectedOnDemand telling whether a connection was made.',
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
    const decorate = (result, connectedOnDemand) => {
      const out = { ...result };
      out.data = { ...(result.data && typeof result.data === 'object' ? result.data : {}), connectedOnDemand };
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
    const state = stateResult.data ?? {};

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
    'Returns data.dialog = null when nothing is blocking, otherwise {title, text, kind, reloadTarget, hwnd, buttons}. kind "reload-prompt" is ' +
    'either the VS prompt "File has been changed outside the environment. Reload the new file?" (reloadTarget "file": a file open in an XAE ' +
    'editor was changed on disk) or the XAE prompt "The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the ' +
    'project?" (reloadTarget "project": a .plcproj was rewritten on disk). For both call ResetSolution: it answers Yes to the project prompt ' +
    '(XAE reloads the project, no close / reopen) and dismisses the file prompt, closes all documents and reopens the solution. ' +
    'Any other dialog is kind "unknown" (reloadTarget null): handle it by hand, or DisconnectIde Quit=true Kill=true for an IDE ConnectIde launched. ' +
    'buttons = [{id, name}] of a Win32 message box (control id 1 OK, 2 Cancel, 6 Yes, 7 No; name is the localized caption).',
  annotations: { readOnlyHint: true },
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

export const composites = [RunLifecycle, QuickRead, GetStatus, GetIdeModalDialog];
export default composites;

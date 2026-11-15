// #258: user consent enforced by the server through MCP elicitation (a form the client shows to
// the user; the agent cannot answer it). Pure logic here (which call needs consent, the form, how a
// response is read, the session memory); index.js only wires it in front of the bridge call.
//
// Fail closed: only action "accept" with content.decision === "approve" runs the call. decline,
// cancel, accept with any other content, a client without capabilities.elicitation, an
// elicitInput that throws or times out: nothing runs. The form always has the required enum field
// `decision`: measured for #258 before the implementation (codex-cli 0.167.0, --dangerously-bypass-approvals-and-sandbox)
// a form without fields is accepted automatically, one with a required enum field is declined;
// `claude -p` (Claude Code 2.1.319, every permission mode) cancels every elicitation.
// Scope (owner decision 2026-11-15: "almost fully automatic with an LLM; ask only where people can
// get hurt"): only two gates. Runtime changes on a target that is not the local UmRT, and
// InstallPackage Approved=true. AddAdsRoute / InstallLibrary / UninstallLibrary, ResetSolution
// Force=true and ConnectIde ProcessId are not gated here (the module keeps its own protections:
// UNSAVED_CHANGES #175, IDE_ATTACH_CONSENT_REQUIRED #281, DryRun defaults).
// The consent memory lives in this server process only (no file, no parameter, no environment
// variable can pre-fill it): a new server process (restart, ReloadRuntime) asks again.

/** elicitInput timeout (ms): about the lifetime of an InstallPackage planToken. */
export const ELICIT_TIMEOUT_MS = 600000;

/** Longest parameter value shown in the form (characters). */
export const MAX_VALUE_CHARS = 60;

const MAX_PARAMS_SHOWN = 12;

/** Tools whose call changes the runtime of the target (gated per target AmsNetId, local-umrt never). */
export const RUNTIME_TOOLS = new Set([
  'EnableConfig',
  'RunTestCycle',
  'RunTest',
  'WriteVariable',
  'SetPlcState',
  'SetSystemState',
  'PlcLogin',
  'SendPlcProgram',
  'SetTcComParameter'
]);

// One fixed English sentence per gate (never text from the agent).
const EFFECT = {
  InstallPackage: 'tcpkg installs or changes TwinCAT software on this PC (IDEs must be closed; the change affects every TwinCAT project on this PC).',
  runtime: 'This changes the running TwinCAT target: TwinCAT may restart, the PLC may stop and start, outputs may switch and axes may move.'
};

/**
 * Which consent a call needs before the bridge runs it, or null.
 * kind 'runtime' = once per target AmsNetId (unless local-umrt); 'install' = InstallPackage
 * Approved=true, every time. Every other call (AddAdsRoute, InstallLibrary, UninstallLibrary,
 * ResetSolution, ConnectIde, ...) goes to the bridge without a form.
 * @param {string} name tool name
 * @param {object} params validated parameters
 * @returns {{kind:'runtime'|'install', effect:string}|null}
 */
export function consentKind(name, params = {}) {
  const p = params ?? {};
  switch (name) {
    case 'InstallPackage':
      return p.Approved === true ? { kind: 'install', effect: EFFECT.InstallPackage } : null;
    case 'SetTcComParameter':
      return p.Online === true && p.DryRun === false ? { kind: 'runtime', effect: EFFECT.runtime } : null;
    default:
      return RUNTIME_TOOLS.has(name) ? { kind: 'runtime', effect: EFFECT.runtime } : null;
  }
}

/**
 * One value for the form: JSON for non-strings, control / format characters (newlines, bidi
 * marks, ...) replaced by a space, whitespace collapsed, cut to `max` characters.
 */
export function sanitizeValue(value, max = MAX_VALUE_CHARS) {
  let s;
  if (typeof value === 'string') s = value;
  else {
    try {
      s = JSON.stringify(value);
    } catch {
      s = String(value);
    }
  }
  s = String(s ?? '')
    .replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const chars = Array.from(s);
  return chars.length > max ? chars.slice(0, max).join('') + '...' : s;
}

/** "Parameter <name>: <value>" lines for the given parameters (sorted, at most 12). */
export function parameterLines(params = {}) {
  const keys = Object.keys(params ?? {}).sort();
  const lines = keys.slice(0, MAX_PARAMS_SHOWN).map((k) => `Parameter ${sanitizeValue(k, 40)}: ${sanitizeValue(params[k])}`);
  if (keys.length > MAX_PARAMS_SHOWN) lines.push(`(${keys.length - MAX_PARAMS_SHOWN} more parameters not shown)`);
  return lines;
}

/** The form schema: one required enum field (a form without fields can be auto-accepted). */
export function consentSchema() {
  return {
    type: 'object',
    properties: {
      decision: {
        type: 'string',
        title: 'Decision',
        description: 'approve = run it now; reject = do not run it',
        enum: ['approve', 'reject']
      }
    },
    required: ['decision']
  };
}

/**
 * The elicitation/create params. Everything in `message` is produced here: fixed sentences, the
 * tool name, target AmsNetId / kind, the remembered InstallPackage plan and sanitized
 * parameter values.
 * @param {{tool:string, gate:{kind:string, effect:string}, params?:object, amsNetId?:string|null,
 *   targetKind?:string|null, plan?:{packageId:string, version:string, command:string}|null}} o
 */
export function buildConsentRequest(o) {
  const lines = [`TcAuto asks you before it runs ${sanitizeValue(o.tool, 40)}.`, `What happens: ${o.gate.effect}`];
  if (o.gate.kind === 'runtime') {
    lines.push(`Target AmsNetId: ${o.amsNetId ? sanitizeValue(o.amsNetId) : 'unknown'}`);
    lines.push(`Target kind: ${sanitizeValue(o.targetKind ?? 'unknown')} (anything but local-umrt is treated as a real machine)`);
    lines.push('Approving allows runtime changes on this target until this TcAuto server process ends.');
  }
  if (o.gate.kind === 'install' && o.plan) {
    lines.push(`Package: ${sanitizeValue(o.plan.packageId)}`);
    lines.push(`Version: ${sanitizeValue(o.plan.version)}`);
    lines.push(`Command: ${sanitizeValue(o.plan.command, 300)}`);
  }
  lines.push(...parameterLines(o.params));
  lines.push('Choose "approve" to run it now or "reject" to stop it. The AI agent cannot answer this form.');
  return { message: lines.join('\n'), requestedSchema: consentSchema() };
}

/** true only for action accept with content.decision === "approve". */
export function isApproved(response) {
  return response?.action === 'accept' && response?.content?.decision === 'approve';
}

/** Hint text for the PowerShell-module alternative, per tool. */
function selfRunHint(tool, plan) {
  if (tool === 'InstallPackage') {
    const cmd = plan?.command ? sanitizeValue(plan.command, 300) : null;
    return cmd
      ? `If the user wants the install, the user runs it in an elevated PowerShell (all IDEs closed): ${cmd} (data.command).`
      : 'If the user wants the install, run InstallPackage without Approved to get a plan and its data.command, which the user can run in an elevated PowerShell.';
  }
  return `Or the user runs it directly with the TcAuto PowerShell module (not through the AI).`;
}

/**
 * Trace value (lib/trace.js `blockedBy`) for a call this gate refused: "consent:<gate kind>", one of
 * consent:runtime, consent:install. Why it was refused is the trace
 * line's errorCode (CONSENT_DECLINED / CONSENT_REQUIRED).
 * @param {{kind:string}} gate result of consentKind
 */
export function consentBlockedBy(gate) {
  return `consent:${gate.kind}`;
}

/**
 * Error result for a refused consent. reason 'declined' -> CONSENT_DECLINED (the user said no,
 * dismissed the form, or accepted without choosing approve); anything else -> CONSENT_REQUIRED
 * (no elicitation support, an elicitation error / timeout, or an InstallPackage token this server
 * process did not issue).
 * @param {'declined'|'unsupported'|'failed'|'unknown-plan'} reason
 */
export function consentErrorResult(tool, reason, extra = {}) {
  const t = sanitizeValue(tool, 40);
  const data = { notRun: true, consent: reason, ...(extra.data ?? {}) };
  if (reason === 'declined') {
    return {
      success: false,
      error: {
        code: 'CONSENT_DECLINED',
        message: `${t} NOT RUN: the confirmation form was not approved (the user declined or closed it, or the client cancelled it on its own, as headless clients such as claude -p do). Nothing was changed.`,
        hint: `Do not retry it on your own and do not work around it with another tool. Ask the user what to do; call ${t} again only when the user wants it (the form will ask again). ${selfRunHint(tool, extra.plan)}`
      },
      data
    };
  }
  if (reason === 'unknown-plan') {
    return {
      success: false,
      error: {
        code: 'CONSENT_REQUIRED',
        message: `${t} NOT RUN: the PlanToken was not issued by this TcAuto server process, so there is no plan to show the user. Nothing was installed.`,
        hint: 'Run InstallPackage without Approved first (same PackageId and Version) to get a plan, show data.plan to the user, then call it with Approved=true and that data.planToken: the server then asks the user in a confirmation form.'
      },
      data
    };
  }
  const why =
    reason === 'unsupported'
      ? 'this MCP client does not support confirmation forms (MCP elicitation)'
      : 'the confirmation form could not be shown or was not answered in time';
  return {
    success: false,
    error: {
      code: 'CONSENT_REQUIRED',
      message: `${t} NOT RUN: it needs the user's confirmation and ${why}. Nothing was changed.`,
      hint: `Tell the user. The user can retry in an interactive MCP client that shows confirmation forms (e.g. Claude Code or Codex CLI in an interactive session; headless modes such as claude -p or codex exec cannot confirm). ${selfRunHint(tool, extra.plan)} Do not work around it with another tool.`
    },
    data
  };
}

/**
 * Per-server-process consent memory. Nothing is persisted.
 *  targets: AmsNetIds (lower case) approved for runtime changes
 *  plans:   InstallPackage planToken -> {packageId, version, command} of plans this process returned
 */
export class ConsentMemory {
  constructor() {
    this.targets = new Set();
    this.plans = new Map();
  }

  hasTarget(amsNetId) {
    return typeof amsNetId === 'string' && amsNetId !== '' && this.targets.has(amsNetId.toLowerCase());
  }

  addTarget(amsNetId) {
    if (typeof amsNetId === 'string' && amsNetId !== '') this.targets.add(amsNetId.toLowerCase());
  }

  /** Remember the plan of an InstallPackage result without Approved (only a plan with a token). */
  rememberPlan(result) {
    const d = result?.success === true && result.data && typeof result.data === 'object' ? result.data : null;
    if (!d || d.executed === true || typeof d.planToken !== 'string' || d.planToken === '') return;
    this.plans.set(d.planToken, {
      packageId: String(d.packageId ?? d.plan?.packageId ?? ''),
      version: String(d.version ?? d.plan?.version ?? ''),
      command: String(d.command ?? d.plan?.command ?? '')
    });
  }

  /** The plan of `token` when it matches PackageId / Version; it is forgotten either way (one use). */
  takePlan(token, packageId, version) {
    if (typeof token !== 'string' || !this.plans.has(token)) return null;
    const plan = this.plans.get(token);
    this.plans.delete(token);
    if (String(packageId ?? '') !== plan.packageId || String(version ?? '') !== plan.version) return null;
    return plan;
  }
}

/** true when the client declared form elicitation (an empty elicitation object means form only). */
export function supportsFormElicitation(caps) {
  const e = caps?.elicitation;
  if (!e || typeof e !== 'object') return false;
  return Object.keys(e).length === 0 || (e.form !== undefined && e.form !== null);
}

/**
 * Ask the user. Never throws.
 * `client.elicit(params, options)` sends elicitation/create and resolves to the raw result (the
 * response is read by isApproved here, so an accept without decision is a decline, not an error).
 * @param {{getClientCapabilities:()=>any, elicit:(p:any, o:any)=>Promise<any>}} client
 * @returns {Promise<'approved'|'declined'|'unsupported'|'failed'>}
 */
export async function askUser(client, request, options = {}) {
  let caps;
  try {
    caps = client.getClientCapabilities();
  } catch {
    caps = null;
  }
  if (!supportsFormElicitation(caps)) return 'unsupported';
  try {
    const res = await client.elicit({ mode: 'form', ...request }, { timeout: ELICIT_TIMEOUT_MS, ...options });
    return isApproved(res) ? 'approved' : 'declined';
  } catch {
    return 'failed';
  }
}

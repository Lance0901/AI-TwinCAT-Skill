// Hints that name the last known IDE (index.js lastIde) after BRIDGE_TIMEOUT / BRIDGE_DIED or
// IDE_MODAL_DIALOG. Whether the advice may include `taskkill` depends on who owns the IDE.
//
// #237: ownership comes from ConnectIde's data.ownedBySession, not from selectedBy. An IDE taken
// over from an orphan launch record (selectedBy 'orphan-takeover') or launched earlier by this
// session (selectedBy 'session-launched') is this session's IDE as much as a 'launched' one.
// A missing or non-boolean ownedBySession is treated as "not ours" (fail closed: never suggest
// killing an IDE the user may have open).

/**
 * @typedef {{ideProcessId:number|null, selectedBy:string|null, ownedBySession:boolean|null, solution:string|null, ideMainHwnd:number|null}} LastIde
 */

/**
 * lastIde record from a successful ConnectIde's data.
 * @param {any} d ConnectIde result.data
 * @returns {LastIde}
 */
export function ideFromConnectData(d) {
  const data = d && typeof d === 'object' ? d : {};
  return {
    ideProcessId: Number.isInteger(data.ideProcessId) && data.ideProcessId > 0 ? data.ideProcessId : null,
    selectedBy: typeof data.selectedBy === 'string' ? data.selectedBy : null,
    ownedBySession: typeof data.ownedBySession === 'boolean' ? data.ownedBySession : null,
    solution: typeof data.solution === 'string' && data.solution.length ? data.solution : null,
    ideMainHwnd: null
  };
}

/** True only when ConnectIde reported ownedBySession === true for this IDE. */
export function isOwnedBySession(ide) {
  return ide?.ownedBySession === true;
}

/** "launched by this server" for a fresh launch, otherwise names the selectedBy that made it ours. */
function ownerPhrase(ide) {
  return ide.selectedBy === 'launched' ? 'launched by this server' : `owned by this session, selectedBy '${ide.selectedBy ?? 'unknown'}'`;
}

/**
 * #263 review: the server knows only the pid of this session's IDE, and a pid can be reused by an
 * IDE the user opened since. `DisconnectIde Quit=true Kill=true` (which checks the start time and
 * ownership) cannot help here: after the bridge was killed the new bridge has no IDE state and
 * answers "not connected" without killing anything (Disconnect-TcIde, checked 2026-11-13 on a fresh
 * module instance). So the hint keeps taskkill but asks to confirm name and start time first.
 */
function confirmBeforeKill(pid) {
  return (
    `first confirm pid ${pid} is still that IDE (a TcXaeShell.exe / devenv.exe started before this session's ConnectIde; ` +
    `the pid may have been reused by an IDE the user opened since): \`powershell -NoProfile -Command "Get-Process -Id ${pid} | Select-Object Name, StartTime"\`. ` +
    `DisconnectIde Quit=true Kill=true cannot kill it here: the restarted bridge has no IDE state.`
  );
}

/** BRIDGE_TIMEOUT / BRIDGE_DIED hint for the last known IDE, or null when no pid is known. */
export function ideHint(ide) {
  const pid = ide?.ideProcessId;
  if (!pid) return null;
  if (isOwnedBySession(ide)) {
    return (
      `The IDE (pid ${pid}, ${ownerPhrase(ide)}) is probably blocked by a modal dialog. ` +
      `Dismiss the dialog if you can; otherwise kill it with \`taskkill /PID ${pid} /T /F\`, but ${confirmBeforeKill(pid)} ` +
      `Then ConnectIde again. Unsaved changes in that IDE will be lost; ask the user before killing it.`
    );
  }
  return `The IDE (pid ${pid}) is not owned by this session (opened by the user or another session); check its window for a modal dialog, dismiss it (or ask the user to), then ConnectIde again.`;
}

/**
 * IDE_MODAL_DIALOG hint.
 * @param {number} pid   IDE pid the probe watched
 * @param {LastIde|null} ide  IDE identity known for that pid (ownedBySession decides the advice)
 * @param {string} title dialog title
 * @param {'killed'|'dequeued'} outcome  what happened to the call (bridge.abortCall)
 */
export function modalHint(pid, ide, title, outcome) {
  // Killing PowerShell does not cancel the DTE operation inside the IDE: once the dialog is
  // dismissed, XAE may still finish (or half-apply) the activation / download / PLC start.
  const lost =
    outcome === 'dequeued'
      ? 'the call was not sent to PowerShell (the call running in the bridge ahead of it may stay blocked by the same dialog until its own timeout)'
      : 'the PowerShell bridge was killed and all IDE/ADS state is lost';
  // #236: only a killed bridge can have left a runtime-changing request half done (a dequeued
  // call never reached PowerShell)
  const after =
    outcome === 'killed'
      ? 'The interrupted operation may still complete or partly apply after the dialog closes. If it had already sent its runtime-changing request (EnableConfig, SetSystemState, SetPlcState; also inside RunLifecycle / RunTestCycle) it is recorded as a lifecycle block (errorCode INTERRUPTED, #236) at the next lifecycle check: do not re-run it; report it to the user, check read-only (GetSystemState / GetPlcState), ClearLifecycleBlock only after the user agreed.'
      : 'Check GetStatus / GetPlcState before re-running the call.';
  if (isOwnedBySession(ide)) {
    return (
      `The IDE (pid ${pid}, ${ownerPhrase(ide)}) shows the modal dialog '${title}'; ${lost}. ` +
      `Dismiss the dialog in the XAE window, or kill the IDE with \`taskkill /PID ${pid} /T /F\` ` +
      `(${confirmBeforeKill(pid)} Unsaved changes in that IDE will be lost; ask the user before killing it), then ConnectIde again. ${after}`
    );
  }
  return `The IDE (pid ${pid}) shows the modal dialog '${title}' and is not owned by this session (opened by the user or another session); ${lost}. Dismiss it in the XAE window (or ask the user to), then ConnectIde again. ${after}`;
}

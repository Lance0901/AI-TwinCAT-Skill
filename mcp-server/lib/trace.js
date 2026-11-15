// Opt-in tool-call trace (JSONL) for AI behaviour evals and debugging.
//
// TCAUTO_TRACE_FILE=<absolute path> -> after every tool call the server appends one JSON line:
//   ts          ISO time the call started
//   durationMs  wall time of the call
//   seq         number of the call in this server process (1, 2, ...; assigned when the call starts)
//   parentSeq   seq of the composite call (RunLifecycle, QuickRead, ...) a step belongs to, else null
//   sessionId   random id generated when the server process started
//   tool        tool name as called
//   args        arguments as received; a string longer than MAX_ARG_CHARS is cut (see truncateArgs)
//   truncated   true when a string in args was cut
//   success     result.success === true
//   errorCode   result.error.code, else null
//   dataKeys    top-level keys of result.data when it is an object, else null (data itself is not stored)
//   resultChars length of the result text the client receives (JSON, 2-space indent)
//   blockedBy   reserved for calls the server refuses before they reach the bridge (#258); null for now
//
// Lines are written when a call ENDS, so a composite's step lines come before the composite's own
// line: sort by seq to get the call order. Each line is one fs.appendFileSync (open with O_APPEND,
// one write, close), so several server processes can share one file. A failed write never changes
// the tool result: the first failure is reported once on stderr, later ones are silent.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export const MAX_ARG_CHARS = 4000;

/** Copy of args with every string longer than max cut to max chars plus a marker. */
export function truncateArgs(args, max = MAX_ARG_CHARS) {
  let truncated = false;
  const walk = (v, depth) => {
    if (typeof v === 'string') {
      if (v.length <= max) return v;
      truncated = true;
      return `${v.slice(0, max)}...[truncated, ${v.length} chars]`;
    }
    if (v === null || typeof v !== 'object' || depth > 20) return v;
    if (Array.isArray(v)) return v.map((x) => walk(x, depth + 1));
    const out = {};
    for (const [k, x] of Object.entries(v)) out[k] = walk(x, depth + 1);
    return out;
  };
  const out = walk(args ?? {}, 0);
  return { args: out, truncated };
}

function dataKeysOf(result) {
  const d = result?.data;
  return d !== null && typeof d === 'object' && !Array.isArray(d) ? Object.keys(d) : null;
}

function resultChars(result) {
  try {
    return JSON.stringify(result, null, 2)?.length ?? 0;
  } catch {
    return null;
  }
}

/**
 * Tracer from the environment. traceFile: env.TCAUTO_TRACE_FILE (unset / empty -> disabled; a
 * relative path is refused with one stderr line, since a runtime started by the launcher runs in the
 * runtime directory and a relative file would land there).
 */
export function createTracer(traceFile, { warn = (m) => console.error(m), now = () => Date.now() } = {}) {
  const file = typeof traceFile === 'string' ? traceFile.trim() : '';
  if (file === '') return disabledTracer();
  if (!path.isAbsolute(file)) {
    warn(`[tcauto-mcp] TCAUTO_TRACE_FILE is not an absolute path (${file}): tool-call trace off`);
    return disabledTracer();
  }
  const sessionId = crypto.randomUUID();
  let seq = 0;
  let warned = false;

  const write = (record) => {
    try {
      fs.appendFileSync(file, `${JSON.stringify(record)}\n`, { encoding: 'utf8', flag: 'a' });
    } catch (err) {
      if (!warned) {
        warned = true;
        warn(`[tcauto-mcp] TCAUTO_TRACE_FILE ${file}: write failed (${err?.code ?? err?.message ?? err}); tool calls are not affected, further write errors are not reported`);
      }
    }
  };

  return {
    enabled: true,
    file,
    sessionId,
    /**
     * Start a traced call. Returns { seq, end(result) }; end never throws.
     * parentSeq: seq of the enclosing composite call, or null.
     */
    begin(tool, args, parentSeq = null) {
      const mySeq = ++seq;
      const t0 = now();
      let done = false;
      return {
        seq: mySeq,
        end(result, { blockedBy = null } = {}) {
          if (done) return;
          done = true;
          try {
            const { args: a, truncated } = truncateArgs(args);
            write({
              ts: new Date(t0).toISOString(),
              durationMs: Math.max(0, now() - t0),
              seq: mySeq,
              parentSeq,
              sessionId,
              tool,
              args: a,
              truncated,
              success: result?.success === true,
              errorCode: result?.success === true ? null : (result?.error?.code ?? null),
              dataKeys: dataKeysOf(result),
              resultChars: resultChars(result),
              blockedBy
            });
          } catch (err) {
            write({ seq: mySeq, sessionId, tool, traceError: String(err?.message ?? err) });
          }
        }
      };
    }
  };
}

function disabledTracer() {
  const noop = { seq: null, end() {} };
  return { enabled: false, file: null, sessionId: null, begin: () => noop };
}

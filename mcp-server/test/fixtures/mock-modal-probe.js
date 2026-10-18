// Mock of bridge/modal-probe.ps1. Test use only.
//
// argv: ... -ProcessId <pid> -IntervalSec <n> -ConfirmScans <n> -ScanScript <path> [-MainHwnd <h>] [-MaxLifetimeSec <s>]
//       (same tail as the real script; stdin is a pipe from Node and ignored here)
// env:
//   MOCK_PROBE_TRIGGER_FILE  polled every 50 ms (no initial interval wait, unlike the real script).
//                            When it exists:
//                              "CRASH"   -> "mock probe crash" on stderr, exit 2
//                              "BADJSON" -> "not json" on stdout, exit 0
//                              otherwise JSON {title,text[,delayMs]} -> one line
//                                {title,text,className:'#32770',isModal:true,processId:<pid>,
//                                 mainWindowEnabled:false,reason:'win32-dialog'}, exit 0;
//                                with delayMs the line is written delayMs after the trigger was seen
//                            Without the file the mock idles until killed.
//   MOCK_PROBE_PID_FILE      process.pid + '\n' is appended on start (tests check the kill)
//   MOCK_PROBE_ECHO=1        writes the argv to stderr once
//   MOCK_PROBE_DEBUG=1       writes "debug: mock routine line" to stderr once
import fs from 'node:fs';

const argv = process.argv.slice(2);
function arg(name) {
  const i = argv.indexOf(name);
  return i !== -1 && i + 1 < argv.length ? argv[i + 1] : undefined;
}
const pid = Number(arg('-ProcessId'));
const intervalSec = Number(arg('-IntervalSec'));

if (process.env.MOCK_PROBE_PID_FILE) fs.appendFileSync(process.env.MOCK_PROBE_PID_FILE, `${process.pid}\n`);
if (process.env.MOCK_PROBE_ECHO === '1') process.stderr.write(`argv ${JSON.stringify(argv)} pid=${pid} interval=${intervalSec}\n`);
if (process.env.MOCK_PROBE_DEBUG === '1') process.stderr.write('debug: mock routine line\n');

const trigger = process.env.MOCK_PROBE_TRIGGER_FILE;

function check() {
  if (!trigger || !fs.existsSync(trigger)) return false;
  let content;
  try {
    content = fs.readFileSync(trigger, 'utf8').trim();
  } catch {
    return false;
  }
  if (content === 'CRASH') {
    process.stderr.write('mock probe crash\n', () => process.exit(2));
    return true;
  }
  if (content === 'BADJSON') {
    process.stdout.write('not json\n', () => process.exit(0));
    return true;
  }
  let d;
  try {
    d = JSON.parse(content);
  } catch {
    return false; // partially written: try again on the next tick
  }
  const line = JSON.stringify({ title: d.title, text: d.text, className: '#32770', isModal: true, processId: pid, mainWindowEnabled: false, reason: 'win32-dialog' });
  const report = () => process.stdout.write(line + '\n', () => process.exit(0));
  if (Number.isFinite(d.delayMs) && d.delayMs > 0) setTimeout(report, d.delayMs);
  else report();
  return true;
}

if (!check()) {
  const timer = setInterval(() => {
    if (check()) clearInterval(timer);
  }, 50);
}

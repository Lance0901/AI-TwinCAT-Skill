// Mock of bridge/modal-probe.ps1. Test use only.
//
// argv: ... -ProcessId <pid> -IntervalSec <n>   (same tail as the real script)
// env:
//   MOCK_PROBE_TRIGGER_FILE  polled every 50 ms (no initial interval wait, unlike the real script).
//                            When it exists:
//                              "CRASH"   -> "mock probe crash" on stderr, exit 2
//                              "BADJSON" -> "not json" on stdout, exit 0
//                              otherwise JSON {title,text} -> one line
//                                {title,text,className:'#32770',isModal:true,processId:<pid>}, exit 0
//                            Without the file the mock idles until killed.
//   MOCK_PROBE_PID_FILE      process.pid + '\n' is appended on start (tests check the kill)
//   MOCK_PROBE_ECHO=1        writes the argv to stderr once
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
  const line = JSON.stringify({ title: d.title, text: d.text, className: '#32770', isModal: true, processId: pid });
  process.stdout.write(line + '\n', () => process.exit(0));
  return true;
}

if (!check()) {
  const timer = setInterval(() => {
    if (check()) clearInterval(timer);
  }, 50);
}

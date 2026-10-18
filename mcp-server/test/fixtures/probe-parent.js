// Test fixture for the orphan-protection test in test/modal-probe.test.js: starts the REAL
// bridge/modal-probe.ps1 through lib/modal-probe.js (stdin piped), prints "probe-pid <n>" once the
// probe has written its startup debug line, then idles until it is killed. The test kills only this
// process and checks that the probe exits.
// argv[2]: pid to watch (the test runner, which outlives this process; default: this process). The
// interval is 60 s, so within the test window the probe can only exit because its stdin closed (a
// watched pid that died would also end it with exit 3, which would hide a broken stdin watch).
import { ModalProbe } from '../../lib/modal-probe.js';

let announced = false;
const probe = new ModalProbe({
  pid: Number(process.argv[2]) > 0 ? Number(process.argv[2]) : process.pid,
  intervalSec: 60,
  onDebug: (msg) => {
    if (!announced && /watching pid/.test(msg)) {
      announced = true;
      process.stdout.write(`probe-pid ${probe.pid}\n`);
    }
  },
  onError: (msg) => process.stderr.write(`${msg}\n`)
});
probe.start();
setInterval(() => {}, 60000);

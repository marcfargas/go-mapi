'use strict';
const {spawn} = require('node:child_process');
const path = require('node:path');
// This node20 action receives the runner's artifact runtime environment.
// The PowerShell controller retains a Job Object and the actual node child.
const env = {...process.env};
// The cached upstream entry is a child, so its action.yml defaults are not
// applied by the runner. Preserve fixed upstream defaults and the reviewed
// hidden-file policy; ambient inputs cannot widen the audited upload set.
env.INPUT_OVERWRITE = 'false';
env['INPUT_INCLUDE-HIDDEN-FILES'] = 'false';
env['INPUT_COMPRESSION-LEVEL'] = '6';
for (const [from, to] of Object.entries({
  'INPUT_JOB-START-COUNTER': 'INPUT_JOB_START_COUNTER',
  'INPUT_COUNTER-FREQUENCY': 'INPUT_COUNTER_FREQUENCY',
  'INPUT_BOOT-MARKER': 'INPUT_BOOT_MARKER'
})) env[to] = env[from];
const script = path.join(process.env.GITHUB_WORKSPACE, 'tests', 'installed-attachment', 'hosted-capability-upload.ps1');
const controller = spawn('pwsh', ['-NoProfile', '-NonInteractive', '-File', script, '-NodeExecutable', process.execPath], {env, stdio: 'inherit'});
controller.once('error', () => {process.exitCode = 1;});
controller.once('exit', (code, signal) => {process.exitCode = signal || code !== 0 ? 1 : 0;});

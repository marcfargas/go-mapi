'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');
let childEnv;
const controller = {once() {return this;}};
const runtime = {
  env: {'GITHUB_WORKSPACE': '/fixture', 'INPUT_NAME': 'evidence', 'INPUT_PATH': '/fixture/evidence',
    'INPUT_IF-NO-FILES-FOUND': 'error', 'INPUT_RETENTION-DAYS': '14',
    'INPUT_JOB-START-COUNTER': '123', 'INPUT_COUNTER-FREQUENCY': '456', 'INPUT_BOOT-MARKER': 'boot',
    // Ambient values must not expand the reviewed fixed upload policy.
    'INPUT_OVERWRITE': 'true', 'INPUT_INCLUDE-HIDDEN-FILES': 'true', 'INPUT_COMPRESSION-LEVEL': '0'},
  execPath: process.execPath,
};
const wrapper = path.resolve(__dirname, '../../.github/actions/hosted-capability-upload/upload.js');
vm.runInNewContext(fs.readFileSync(wrapper, 'utf8'), {
  process: runtime,
  require(name) {
    if (name === 'node:child_process') return {spawn(exe, args, options) {
      assert.equal(exe, 'pwsh'); assert.equal(args.at(-1), process.execPath);
      childEnv = options.env; return controller;
    }};
    return require(name);
  },
});
assert.equal(childEnv.INPUT_OVERWRITE, 'false');
assert.equal(childEnv['INPUT_INCLUDE-HIDDEN-FILES'], 'false');
assert.equal(childEnv['INPUT_COMPRESSION-LEVEL'], '6');
assert.equal(childEnv.INPUT_JOB_START_COUNTER, '123');
assert.equal(childEnv.INPUT_COUNTER_FREQUENCY, '456');
assert.equal(childEnv.INPUT_BOOT_MARKER, 'boot');
assert.equal(childEnv.INPUT_PATH, '/fixture/evidence');
assert.equal(childEnv['INPUT_RETENTION-DAYS'], '14');
console.log('PRODUCTION_UPLOAD_WRAPPER_FIXED_INPUT_ENV_PASSED');

if (!process.argv[2]) {
  console.log('UPSTREAM_COMPILED_INPUT_PARSER_UNRUN: provide retained exact sampled bundle path; wrapper test passed');
  process.exit(0);
}
const bytes = fs.readFileSync(process.argv[2]);
assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),
  '0165b8a75330f3228f2c7a234b4ff8a107b9139c2b519147f4c8e9fe99b262d8');
const source = bytes.toString('utf8');
const marker = 'var __webpack_exports__ = __nccwpck_require__(36664);';
assert.equal(source.split(marker).length, 2);
// Execute the retained compiled parser and its actual bundled @actions/core.
// Disable startup only, export the bundle require; no action/network entry runs.
const transformed = source.replace(marker, 'var __webpack_exports__ = __nccwpck_require__;');
function inputs(env) {
  const sandbox = {module: {exports: {}}, exports: {}, require, process: {...process, env},
    __dirname: path.dirname(process.argv[2]), __filename: process.argv[2], console, Buffer,
    setTimeout, clearTimeout, setInterval, clearInterval, URL, URLSearchParams, TextEncoder, TextDecoder,
    AbortSignal, AbortController, Blob, FormData, Headers, Request, Response,
    ReadableStream, WritableStream, TransformStream, performance,
    fetch() {throw new Error('Network is suppressed in the parser regression');}};
  sandbox.global = sandbox;
  for (const key of Object.getOwnPropertyNames(globalThis)) {
    if (!(key in sandbox)) {
      try {sandbox[key] = globalThis[key];} catch { /* optional Node host global */ }
    }
  }
  vm.runInNewContext(transformed, sandbox, {timeout: 5000});
  // Module ID is pinned to this exact compiled bundle, never guessed at runtime.
  return sandbox.module.exports(67022).getInputs();
}
const parsed = inputs(childEnv);
assert.equal(parsed.overwrite, false); assert.equal(parsed.includeHiddenFiles, false);
assert.equal(parsed.compressionLevel, 6); assert.equal(parsed.retentionDays, 14);
assert.equal(parsed.artifactName, 'evidence'); assert.equal(parsed.searchPath, '/fixture/evidence');
const missing = {...childEnv}; delete missing.INPUT_OVERWRITE;
assert.throws(() => inputs(missing), /Input does not meet YAML 1.2/);
console.log('EXACT_UPSTREAM_COMPILED_PARSER_WITH_PRODUCTION_WRAPPER_ENV_PASSED;NETWORK_AND_MAIN_STARTUP_SUPPRESSED');

// Copyright (c) 2026 Alex313031
//
// A smoke test for the standalone Node build on legacy Windows.
//
//   node node_test.js              run everything
//   node node_test.js --only=fs    run the tests whose name contains "fs"
//   node node_test.js --list       list the tests and exit
//   node node_test.js --verbose    print stack traces for failures
//   node node_test.js --net        also run the tests that need the internet
//
// It needs nothing but node.exe: no npm, no modules, no network unless asked.
// Each test is small and independent, and is named for the part of Node it
// goes through, so a failure says where to look. Most of them exist because a
// particular Win32 function behind them is one Windows XP does not have and
// winwrap supplies -- the comment on each says which.
//
// Results are PASS, FAIL, or SKIP. A SKIP is something this system cannot do
// and is not expected to (symbolic links on XP, IPv6 where it is not
// installed); it is not a failure. The exit code is the number of FAILs.
//
// ASCII only, on purpose: an XP console in a legacy code page turns anything
// else into noise.

'use strict';

const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const args = process.argv.slice(2);
const flag = (name) => args.includes('--' + name);
const option = (name) => {
  const prefix = '--' + name + '=';
  const found = args.find((a) => a.startsWith(prefix));
  return found ? found.slice(prefix.length) : null;
};

const VERBOSE = flag('verbose');
const WITH_NET = flag('net');
const ONLY = option('only');
const IS_WINDOWS = process.platform === 'win32';
const TEST_TIMEOUT_MS = 20000;

// node:sqlite announces that it is experimental, on stderr, in the middle of
// the results. Everything else still warns as usual.
const emitWarning = process.emitWarning;
process.emitWarning = function(warning, ...rest) {
  const type = rest[0] && typeof rest[0] === 'object' ? rest[0].type : rest[0];
  if (type === 'ExperimentalWarning') return;
  return emitWarning.call(process, warning, ...rest);
};

// Thrown by a test to say "not applicable here" rather than "broken".
class Skip extends Error {}
const skip = (reason) => { throw new Skip(reason); };

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

// Notes a test wants shown beside its result: the value it read, mostly, so
// that a human can judge what the test cannot ("is that really my time zone").
let notes = [];
const note = (text) => notes.push(String(text));

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Burns about `ms` of this thread's processor time.
function burn(ms) {
  const end = Date.now() + ms;
  let x = 0;
  while (Date.now() < end) {
    for (let i = 0; i < 10000; i++) x = (x + i * i) % 1000003;
  }
  return x;
}

// A scratch directory, made on first use and removed at the end.
let scratch = null;
function scratchDir() {
  if (!scratch) scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'node-test-'));
  return scratch;
}

// Runs this same node.exe on a one-line script.
function runNode(script, extra) {
  const { spawnSync } = require('node:child_process');
  const result = spawnSync(process.execPath, ['-e', script], Object.assign({
    encoding: 'utf8',
    timeout: 15000,
  }, extra));
  if (result.error) throw result.error;
  return result;
}

// ---------------------------------------------------------------------------
// The process and the machine
// ---------------------------------------------------------------------------

test('process: versions and platform', () => {
  assert.match(process.version, /^v\d+\.\d+\.\d+/);
  assert.ok(process.versions.v8 && process.versions.uv && process.versions.openssl);
  note(`${process.version} ${process.arch}, v8 ${process.versions.v8}, ` +
       `uv ${process.versions.uv}, openssl ${process.versions.openssl}`);
});

test('os: release, hostname, user, directories', () => {
  // hostname is patch 01 (GetHostNameW is Windows 8's).
  assert.ok(os.hostname().length > 0, 'empty hostname');
  assert.ok(os.release().length > 0);
  assert.ok(fs.existsSync(os.tmpdir()), 'tmpdir does not exist');
  assert.ok(fs.existsSync(os.homedir()), 'homedir does not exist');
  assert.ok(os.userInfo().username.length > 0);
  note(`${os.type()} ${os.release()} "${os.version()}", host ${os.hostname()}, ` +
       `user ${os.userInfo().username}`);
});

test('os: processors and memory', () => {
  // cpus() is GetLogicalProcessorInformation territory; memoryUsage() is
  // GetProcessMemoryInfo, which patch 17 takes from psapi.dll.
  const cpus = os.cpus();
  assert.ok(cpus.length > 0, 'no processors reported');
  assert.ok(os.availableParallelism() > 0);
  assert.ok(os.totalmem() > 0 && os.freemem() > 0);
  const usage = process.memoryUsage();
  assert.ok(usage.rss > 0 && usage.heapUsed > 0, 'memoryUsage returned zeros');
  note(`${cpus.length} x ${cpus[0].model.trim()} @ ${cpus[0].speed} MHz, ` +
       `${Math.round(os.totalmem() / 1048576)} MB, rss ${Math.round(usage.rss / 1048576)} MB`);
});

test('os: uptime', () => {
  // GetTickCount64, the first function winwrap ever supplied.
  const first = os.uptime();
  assert.ok(first > 0, 'uptime is not positive');
  note(`${Math.round(first)} s`);
});

test('os: network interfaces', () => {
  const interfaces = os.networkInterfaces();
  const names = Object.keys(interfaces);
  assert.ok(names.length > 0, 'no network interfaces at all');
  const loopback = names.some((n) => interfaces[n].some((a) => a.internal));
  assert.ok(loopback, 'no loopback interface');
  note(names.join(', '));
});

test('os: priority', () => {
  const before = os.getPriority();
  os.setPriority(before);
  assert.strictEqual(os.getPriority(), before);
});

test('process: title', () => {
  // Patch 02: uv_get_process_title crashed on Windows 7.
  const before = process.title;
  assert.strictEqual(typeof before, 'string');
  process.title = 'node_test';
  assert.strictEqual(process.title, 'node_test');
  process.title = before;
});

test('process: cwd and chdir', () => {
  const before = process.cwd();
  process.chdir(os.tmpdir());
  assert.ok(process.cwd().length > 0);
  process.chdir(before);
  assert.strictEqual(process.cwd(), before);
});

test('process: cpuUsage and resourceUsage', () => {
  const before = process.cpuUsage();
  burn(250);
  const used = process.cpuUsage(before);
  assert.ok(used.user + used.system > 0, 'a quarter second of work used no processor time');
  assert.ok(process.resourceUsage().maxRSS > 0);
  note(`${Math.round((used.user + used.system) / 1000)} ms charged for ~250 ms of work`);
});

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

test('time: default time zone', () => {
  // GetDynamicTimeZoneInformation. ICU turns the zone's registry key name into
  // an IANA zone; XP does not record the key name, so winwrap searches for it.
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const offset = new Date().getTimezoneOffset();
  assert.ok(zone && zone.length > 0, 'no time zone resolved');
  note(`${zone}, UTC offset ${-offset} min, now ${new Date().toString()}`);
  // The one thing that can be checked without knowing where the machine is:
  // a zone of plain UTC with a non-zero offset means the lookup fell through.
  if (/^(UTC|Etc\/UTC|Etc\/Unknown)$/.test(zone)) {
    assert.strictEqual(offset, 0, `zone resolved to ${zone} but the offset is ${-offset} min`);
  }
});

test('time: wall clock advances', async () => {
  // Patch 03: GetSystemTimePreciseAsFileTime is Windows 8's.
  const first = Date.now();
  await sleep(120);
  const elapsed = Date.now() - first;
  assert.ok(elapsed >= 90 && elapsed < 2000, `120 ms sleep measured as ${elapsed} ms`);
  assert.ok(first > Date.UTC(2020, 0, 1), 'the clock reads before 2020');
});

test('time: monotonic clocks', async () => {
  const { performance } = require('node:perf_hooks');
  const a = performance.now();
  const h = process.hrtime.bigint();
  await sleep(100);
  const b = performance.now();
  const elapsed = Number(process.hrtime.bigint() - h) / 1e6;
  assert.ok(b - a >= 70 && b - a < 2000, `performance.now measured 100 ms as ${b - a}`);
  assert.ok(elapsed >= 70 && elapsed < 2000, `hrtime measured 100 ms as ${elapsed}`);
});

test('time: timers', async () => {
  // Timer accuracy: CreateWaitableTimerExW refuses the high-resolution flag on
  // XP and V8 has to fall back, so this is that fallback working.
  let ticks = 0;
  const interval = setInterval(() => ticks++, 20);
  const order = [];
  setImmediate(() => order.push('immediate'));
  process.nextTick(() => order.push('tick'));
  queueMicrotask(() => order.push('microtask'));
  await sleep(250);
  clearInterval(interval);
  assert.ok(ticks >= 5 && ticks <= 15, `a 20 ms interval fired ${ticks} times in 250 ms`);
  assert.deepStrictEqual([...order].sort(), ['immediate', 'microtask', 'tick']);
  assert.strictEqual(order[2], 'immediate', 'setImmediate ran ahead of the microtask queue');
  note(`20 ms interval fired ${ticks} times in 250 ms`);
});

test('time: event loop delay monitor', async () => {
  const { monitorEventLoopDelay } = require('node:perf_hooks');
  const histogram = monitorEventLoopDelay({ resolution: 10 });
  histogram.enable();
  await sleep(150);
  histogram.disable();
  assert.ok(histogram.max > 0, 'the event loop delay histogram recorded nothing');
});

// ---------------------------------------------------------------------------
// Locale
// ---------------------------------------------------------------------------

test('intl: default locale and formatting', () => {
  // ICU reaches the Vista locale functions: LCIDToLocaleName, GetLocaleInfoEx,
  // ResolveLocaleName and the formatters.
  const locale = Intl.DateTimeFormat().resolvedOptions().locale;
  assert.ok(locale && locale.length >= 2, 'no default locale');
  assert.strictEqual(new Intl.NumberFormat('en-US').format(1234567.891), '1,234,567.891');
  assert.strictEqual(
      new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', dateStyle: 'medium' })
          .format(new Date(Date.UTC(2026, 10, 25))),
      'Nov 25, 2026');
  assert.strictEqual('STRASSE'.localeCompare('strasse', 'en', { sensitivity: 'base' }), 0);
  note(`${locale}; ${new Date().toLocaleString()}; ${(1234.5).toLocaleString()}`);
});

// ---------------------------------------------------------------------------
// File system
// ---------------------------------------------------------------------------

test('fs: write, read, append, rename, stat, remove', () => {
  const dir = scratchDir();
  const a = path.join(dir, 'a.txt');
  const b = path.join(dir, 'b.txt');
  fs.writeFileSync(a, 'hello');
  fs.appendFileSync(a, ' world');
  assert.strictEqual(fs.readFileSync(a, 'utf8'), 'hello world');
  fs.renameSync(a, b);
  assert.ok(!fs.existsSync(a) && fs.existsSync(b));
  const stat = fs.statSync(b);
  assert.ok(stat.isFile() && stat.size === 11);
  assert.strictEqual(fs.statSync(b, { bigint: true }).size, 11n);
  fs.copyFileSync(b, a);
  assert.deepStrictEqual(fs.readdirSync(dir).sort(), ['a.txt', 'b.txt']);
  fs.unlinkSync(a);
  fs.unlinkSync(b);
});

test('fs: directories, recursive', () => {
  const deep = path.join(scratchDir(), 'one', 'two', 'three');
  fs.mkdirSync(deep, { recursive: true });
  fs.writeFileSync(path.join(deep, 'f'), 'x');
  const listed = fs.readdirSync(path.join(scratchDir(), 'one'), { recursive: true });
  assert.ok(listed.length >= 3, `recursive readdir found ${listed.length} entries`);
  fs.rmSync(path.join(scratchDir(), 'one'), { recursive: true, force: true });
  assert.ok(!fs.existsSync(path.join(scratchDir(), 'one')));
});

test('fs: realpath', () => {
  // realpath.native is GetFinalPathNameByHandleW, which is Vista's.
  const file = path.join(scratchDir(), 'real.txt');
  fs.writeFileSync(file, 'x');
  const js = fs.realpathSync(file);
  const native = fs.realpathSync.native(file);
  assert.strictEqual(js.toLowerCase(), native.toLowerCase());
  assert.ok(fs.existsSync(native));
  fs.unlinkSync(file);
  note(native);
});

test('fs: file descriptors, truncate, utimes, fsync', () => {
  // Truncation and times go through SetFileInformationByHandle.
  const file = path.join(scratchDir(), 'fd.bin');
  const fd = fs.openSync(file, 'w+');
  fs.writeSync(fd, Buffer.alloc(4096, 7));
  fs.fsyncSync(fd);
  fs.ftruncateSync(fd, 100);
  assert.strictEqual(fs.fstatSync(fd).size, 100);
  const out = Buffer.alloc(10);
  assert.strictEqual(fs.readSync(fd, out, 0, 10, 0), 10);
  assert.strictEqual(out[9], 7);
  fs.closeSync(fd);
  const when = new Date(Date.UTC(2020, 5, 15, 12, 0, 0));
  fs.utimesSync(file, when, when);
  assert.ok(Math.abs(fs.statSync(file).mtimeMs - when.getTime()) < 2000, 'utimes did not stick');
  fs.unlinkSync(file);
});

test('fs: promises and streams', async () => {
  const file = path.join(scratchDir(), 'stream.txt');
  await fs.promises.writeFile(file, 'x'.repeat(200000));
  let total = 0;
  for await (const chunk of fs.createReadStream(file)) total += chunk.length;
  assert.strictEqual(total, 200000);
  const copy = file + '.copy';
  await require('node:stream/promises').pipeline(
      fs.createReadStream(file), fs.createWriteStream(copy));
  assert.strictEqual((await fs.promises.stat(copy)).size, 200000);
  await fs.promises.rm(file);
  await fs.promises.rm(copy);
});

test('fs: symbolic links', () => {
  // CreateSymbolicLinkW. XP has no symbolic links, and later Windows wants a
  // privilege for them, so a refusal is a skip. What matters is that the
  // refusal arrives as an error and not as a crash.
  const target = path.join(scratchDir(), 'target.txt');
  const link = path.join(scratchDir(), 'link.txt');
  fs.writeFileSync(target, 'linked');
  try {
    fs.symlinkSync(target, link);
  } catch (error) {
    fs.unlinkSync(target);
    skip(`not available here (${error.code})`);
  }
  assert.strictEqual(fs.readFileSync(link, 'utf8'), 'linked');
  assert.ok(fs.lstatSync(link).isSymbolicLink());
  fs.unlinkSync(link);
  fs.unlinkSync(target);
});

test('fs: watch', async () => {
  const dir = path.join(scratchDir(), 'watched');
  fs.mkdirSync(dir);
  let seen = false;
  const watcher = fs.watch(dir, () => { seen = true; });
  await sleep(100);
  fs.writeFileSync(path.join(dir, 'new.txt'), 'x');
  for (let i = 0; i < 30 && !seen; i++) await sleep(50);
  watcher.close();
  fs.rmSync(dir, { recursive: true, force: true });
  assert.ok(seen, 'no change event within 1.5 s of creating a file');
});

// ---------------------------------------------------------------------------
// Buffers, compression, crypto
// ---------------------------------------------------------------------------

test('zlib: gzip, deflate, brotli', () => {
  const zlib = require('node:zlib');
  const input = Buffer.from('legacy windows '.repeat(2000));
  assert.ok(zlib.gunzipSync(zlib.gzipSync(input)).equals(input));
  assert.ok(zlib.inflateSync(zlib.deflateSync(input)).equals(input));
  assert.ok(zlib.brotliDecompressSync(zlib.brotliCompressSync(input)).equals(input));
  note(`${input.length} -> ${zlib.gzipSync(input).length} bytes gzipped`);
});

test('crypto: hashes and random', () => {
  const crypto = require('node:crypto');
  assert.strictEqual(
      crypto.createHash('sha256').update('abc').digest('hex'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  assert.strictEqual(
      crypto.createHash('md5').update('abc').digest('hex'),
      '900150983cd24fb0d6963f7d28e17f72');
  const a = crypto.randomBytes(32);
  const b = crypto.randomBytes(32);
  assert.ok(!a.equals(b), 'two random buffers were identical');
  assert.match(crypto.randomUUID(), /^[0-9a-f-]{36}$/);
});

test('crypto: cipher, key derivation, signatures', () => {
  const crypto = require('node:crypto');
  const key = crypto.pbkdf2Sync('password', 'salt', 1000, 32, 'sha256');
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const sealed = Buffer.concat([cipher.update('secret message'), cipher.final()]);
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(cipher.getAuthTag());
  const opened = Buffer.concat([decipher.update(sealed), decipher.final()]);
  assert.strictEqual(opened.toString(), 'secret message');

  const pair = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const signature = crypto.sign('sha256', Buffer.from('data'), pair.privateKey);
  assert.ok(crypto.verify('sha256', Buffer.from('data'), pair.publicKey, signature));
});

test('crypto: web crypto', async () => {
  const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode('abc'));
  assert.strictEqual(Buffer.from(digest).toString('hex'),
                     'a9993e364706816aba3e25717850c26c9cd0d89d');
  assert.strictEqual(crypto.getRandomValues(new Uint8Array(16)).length, 16);
});

test('tls: ciphers and root certificates', () => {
  const tls = require('node:tls');
  assert.ok(tls.getCiphers().length > 10, 'almost no TLS ciphers');
  assert.ok(tls.rootCertificates.length > 10, 'almost no bundled root certificates');
  note(`${tls.getCiphers().length} ciphers, ${tls.rootCertificates.length} roots, ` +
       `default max ${tls.DEFAULT_MAX_VERSION}`);
});

// ---------------------------------------------------------------------------
// V8
// ---------------------------------------------------------------------------

test('v8: language features and the optimiser', () => {
  assert.strictEqual(2n ** 64n, 18446744073709551616n);
  assert.deepStrictEqual(structuredClone({ a: [1, { b: 2 }] }), { a: [1, { b: 2 }] });
  assert.deepStrictEqual([...new Intl.Segmenter('en', { granularity: 'word' })
      .segment('two words')].filter((s) => s.isWordLike).length, 2);
  // Long enough, and hot enough, to be compiled by the optimising tiers.
  const hot = (n) => { let s = 0; for (let i = 0; i < n; i++) s += Math.sqrt(i) | 0; return s; };
  let last = 0;
  for (let i = 0; i < 200; i++) last = hot(20000);
  assert.strictEqual(last, hot(20000));
  const stats = require('node:v8').getHeapStatistics();
  assert.ok(stats.total_heap_size > 0);
  note(`heap limit ${Math.round(stats.heap_size_limit / 1048576)} MB`);
});

test('v8: WebAssembly', () => {
  // (module (func (export "add") (param i32 i32) (result i32)
  //   local.get 0 local.get 1 i32.add))
  const bytes = Uint8Array.from([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60,
    0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20,
    0x00, 0x20, 0x01, 0x6a, 0x0b]);
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes));
  assert.strictEqual(instance.exports.add(40, 2), 42);
});

test('v8: garbage collection under pressure', () => {
  // Enough allocation to force several collections, which is where the
  // thread pool, condition variables and FlushProcessWriteBuffers get used.
  let kept = [];
  for (let round = 0; round < 40; round++) {
    kept = [];
    for (let i = 0; i < 20000; i++) kept.push({ i, text: 'x'.repeat(20) + i });
  }
  assert.strictEqual(kept.length, 20000);
});

// ---------------------------------------------------------------------------
// Threads and processes
// ---------------------------------------------------------------------------

test('worker: message round trip', async () => {
  const { Worker } = require('node:worker_threads');
  const worker = new Worker(
      'require("node:worker_threads").parentPort.on("message", (m) => ' +
      'require("node:worker_threads").parentPort.postMessage(m * 2));',
      { eval: true });
  const answer = await new Promise((resolve, reject) => {
    worker.once('message', resolve);
    worker.once('error', reject);
    worker.postMessage(21);
  });
  await worker.terminate();
  assert.strictEqual(answer, 42);
});

test('worker: Atomics.wait and notify', async () => {
  // A thread blocking and being woken by another: SRW locks and condition
  // variables, both of which winwrap implements on XP.
  const { Worker } = require('node:worker_threads');
  const shared = new Int32Array(new SharedArrayBuffer(4));
  const worker = new Worker(
      'const { parentPort, workerData } = require("node:worker_threads");' +
      'const r = Atomics.wait(workerData, 0, 0, 10000);' +
      'parentPort.postMessage(r + ":" + Atomics.load(workerData, 0));',
      { eval: true, workerData: shared });
  const result = new Promise((resolve, reject) => {
    worker.once('message', resolve);
    worker.once('error', reject);
  });
  await sleep(200);
  Atomics.store(shared, 0, 7);
  Atomics.notify(shared, 0);
  assert.strictEqual(await result, 'ok:7');
  await worker.terminate();
});

test('worker: several at once', async () => {
  const { Worker } = require('node:worker_threads');
  const run = (n) => new Promise((resolve, reject) => {
    const worker = new Worker(
        'const { parentPort, workerData } = require("node:worker_threads");' +
        'let s = 0; for (let i = 0; i < 2e6; i++) s += i % workerData;' +
        'parentPort.postMessage(s);',
        { eval: true, workerData: n });
    worker.once('message', resolve);
    worker.once('error', reject);
  });
  const results = await Promise.all([3, 5, 7, 11].map(run));
  assert.strictEqual(results.length, 4);
  assert.ok(results.every((r) => r > 0));
});

test('child_process: spawnSync of node itself', () => {
  const result = runNode('process.stdout.write(String(6 * 7))');
  assert.strictEqual(result.status, 0, `exit status ${result.status}: ${result.stderr}`);
  assert.strictEqual(result.stdout, '42');
});

test('child_process: exit code, stderr and environment', () => {
  const result = runNode(
      'process.stderr.write(process.env.NODE_TEST_VALUE); process.exit(3)',
      { env: Object.assign({}, process.env, { NODE_TEST_VALUE: 'from-parent' }) });
  assert.strictEqual(result.status, 3);
  assert.strictEqual(result.stderr, 'from-parent');
});

test('child_process: the shell', () => {
  const { execSync } = require('node:child_process');
  const out = execSync('echo shell-ok', { encoding: 'utf8', timeout: 15000 });
  assert.match(out, /shell-ok/);
});

test('child_process: async spawn with piped stdio', async () => {
  const { spawn } = require('node:child_process');
  const child = spawn(process.execPath,
      ['-e', 'process.stdin.on("data", (d) => process.stdout.write(d.toString().toUpperCase()))']);
  let out = '';
  child.stdout.on('data', (d) => { out += d; });
  const exited = new Promise((resolve) => child.once('close', resolve));
  child.stdin.end('piped');
  assert.strictEqual(await exited, 0);
  assert.strictEqual(out, 'PIPED');
});

test('child_process: fork and IPC', async () => {
  // IPC is a named pipe, and libuv's pipe code is the heaviest user of the
  // completion-port and cancellation functions winwrap stands in for.
  const { fork } = require('node:child_process');
  const script = path.join(scratchDir(), 'ipc-child.js');
  fs.writeFileSync(script,
      'process.on("message", (m) => { process.send({ echo: m.value + 1 }); process.exit(0); });');
  const child = fork(script, [], { silent: true });
  const reply = await new Promise((resolve, reject) => {
    child.once('message', resolve);
    child.once('error', reject);
    child.send({ value: 41 });
  });
  await new Promise((resolve) => child.once('exit', resolve));
  fs.unlinkSync(script);
  assert.deepStrictEqual(reply, { echo: 42 });
});

test('child_process: kill', async () => {
  const { spawn } = require('node:child_process');
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)']);
  await sleep(300);
  const exited = new Promise((resolve) => child.once('exit', (code, signal) => resolve(signal)));
  assert.ok(child.kill(), 'kill reported failure');
  assert.strictEqual(await exited, 'SIGTERM');
});

// ---------------------------------------------------------------------------
// Networking, all on this machine
// ---------------------------------------------------------------------------

// Starts `server` on the loopback address and resolves to its port.
function listen(server, host) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, host || '127.0.0.1', () => resolve(server.address().port));
  });
}

async function tcpEcho(host) {
  const net = require('node:net');
  const server = net.createServer((socket) => socket.pipe(socket));
  const port = await listen(server, host);
  const reply = await new Promise((resolve, reject) => {
    const client = net.connect(port, host, () => client.end('echo me'));
    let data = '';
    client.on('data', (d) => { data += d; });
    client.on('end', () => resolve(data));
    client.on('error', reject);
  });
  await new Promise((resolve) => server.close(resolve));
  return reply;
}

test('net: TCP over IPv4 loopback', async () => {
  assert.strictEqual(await tcpEcho('127.0.0.1'), 'echo me');
});

test('net: TCP over IPv6 loopback', async () => {
  try {
    assert.strictEqual(await tcpEcho('::1'), 'echo me');
  } catch (error) {
    if (/EADDRNOTAVAIL|EAFNOSUPPORT|EINVAL|ENOTSUP|EPROTONOSUPPORT/.test(error.code || '')) {
      skip(`IPv6 is not installed here (${error.code})`);
    }
    throw error;
  }
});

test('net: named pipe', async () => {
  const net = require('node:net');
  const name = IS_WINDOWS ?
      `\\\\.\\pipe\\node-test-${process.pid}` :
      path.join(scratchDir(), 'pipe.sock');
  const server = net.createServer((socket) => socket.pipe(socket));
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(name, resolve);
  });
  const reply = await new Promise((resolve, reject) => {
    const client = net.connect(name, () => client.end('through the pipe'));
    let data = '';
    client.on('data', (d) => { data += d; });
    client.on('end', () => resolve(data));
    client.on('error', reject);
  });
  await new Promise((resolve) => server.close(resolve));
  assert.strictEqual(reply, 'through the pipe');
});

test('net: UDP loopback', async () => {
  const dgram = require('node:dgram');
  const receiver = dgram.createSocket('udp4');
  const sender = dgram.createSocket('udp4');
  await new Promise((resolve, reject) => {
    receiver.once('error', reject);
    receiver.bind(0, '127.0.0.1', resolve);
  });
  const message = await new Promise((resolve, reject) => {
    receiver.once('message', (m) => resolve(m.toString()));
    sender.send('datagram', receiver.address().port, '127.0.0.1', (e) => e && reject(e));
  });
  receiver.close();
  sender.close();
  assert.strictEqual(message, 'datagram');
});

test('net: HTTP server, http.get and fetch', async () => {
  const http = require('node:http');
  const server = http.createServer((request, response) => {
    response.setHeader('content-type', 'text/plain');
    response.end('served ' + request.url);
  });
  const port = await listen(server);
  const viaGet = await new Promise((resolve, reject) => {
    http.get(`http://127.0.0.1:${port}/get`, (response) => {
      let body = '';
      response.on('data', (d) => { body += d; });
      response.on('end', () => resolve(body));
    }).on('error', reject);
  });
  const viaFetch = await (await fetch(`http://127.0.0.1:${port}/fetch`)).text();
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
  assert.strictEqual(viaGet, 'served /get');
  assert.strictEqual(viaFetch, 'served /fetch');
});

test('dns: lookup of localhost', async () => {
  const dns = require('node:dns');
  const result = await dns.promises.lookup('localhost', { all: true });
  assert.ok(result.length > 0, 'localhost did not resolve');
  assert.ok(result.some((r) => r.address === '127.0.0.1' || r.address === '::1'),
            `localhost resolved to ${JSON.stringify(result)}`);
  note(result.map((r) => r.address).join(', '));
});

test('dns: c-ares configuration', async () => {
  // Patch 16: c-ares reads the system's resolver settings through functions
  // that are Vista's unless told to use the older ones. getServers() is that
  // code having run; a crash here, rather than an odd list, is the failure.
  const dns = require('node:dns');
  const servers = dns.getServers();
  assert.ok(Array.isArray(servers));
  note(servers.length ? servers.join(', ') : 'no DNS servers configured');
  // resolve() of localhost goes through c-ares itself, including its
  // loopback-address code, which is the other half of that patch.
  try {
    const addresses = await dns.promises.resolve4('localhost');
    assert.ok(addresses.includes('127.0.0.1'), `resolve4 gave ${addresses}`);
  } catch (error) {
    if (!/ENOTFOUND|ECONNREFUSED|ETIMEOUT|ESERVFAIL|ENODATA|EREFUSED/.test(error.code || '')) {
      throw error;
    }
    note(`resolve4('localhost') answered ${error.code}, which a machine with no resolver may`);
  }
});

// ---------------------------------------------------------------------------
// Things that ship inside node.exe
// ---------------------------------------------------------------------------

test('sqlite: in-memory database', () => {
  // SQLite's Windows layer keeps a table of function addresses, which is what
  // needed winwrap's plain-name redirectors before node.exe would link.
  let sqlite;
  try {
    sqlite = require('node:sqlite');
  } catch (error) {
    skip(`node:sqlite is not in this build (${error.code})`);
  }
  const db = new sqlite.DatabaseSync(':memory:');
  db.exec('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
  const insert = db.prepare('INSERT INTO t (name) VALUES (?)');
  for (const name of ['xp', 'vista', 'seven']) insert.run(name);
  const rows = db.prepare('SELECT name FROM t ORDER BY id').all();
  assert.deepStrictEqual(rows.map((r) => r.name), ['xp', 'vista', 'seven']);
  db.close();
});

test('sqlite: database on disk', () => {
  let sqlite;
  try {
    sqlite = require('node:sqlite');
  } catch (error) {
    skip(`node:sqlite is not in this build (${error.code})`);
  }
  // On disk is where SQLite's file locking and its time source are used.
  const file = path.join(scratchDir(), 'test.db');
  let db = new sqlite.DatabaseSync(file);
  db.exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES (datetime('now'))");
  db.close();
  db = new sqlite.DatabaseSync(file);
  const row = db.prepare('SELECT v FROM t').get();
  db.close();
  fs.unlinkSync(file);
  assert.match(row.v, /^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/);
  note(`datetime('now') = ${row.v} UTC`);
});

test('modules: require, JSON and dynamic import', async () => {
  const dir = scratchDir();
  fs.writeFileSync(path.join(dir, 'data.json'), '{"answer": 42}');
  fs.writeFileSync(path.join(dir, 'cjs.js'), 'module.exports = require("./data.json").answer;');
  fs.writeFileSync(path.join(dir, 'esm.mjs'), 'export const value = 6 * 7;');
  assert.strictEqual(require(path.join(dir, 'cjs.js')), 42);
  const esm = await import(require('node:url').pathToFileURL(path.join(dir, 'esm.mjs')).href);
  assert.strictEqual(esm.value, 42);
  assert.strictEqual((await import('node:os')).EOL, os.EOL);
});

test('process: diagnostic report', () => {
  // Gathers nearly everything above in one call -- libuv handles, the heap,
  // network interfaces, loaded modules -- and symbolises the native stack
  // through dbghelp, which is delay-loaded and partly shimmed.
  const report = process.report.getReport();
  assert.ok(report.header && report.javascriptStack, 'the report is missing sections');
  assert.ok(report.sharedObjects.length > 0, 'the report lists no loaded modules');
  note(`${report.sharedObjects.length} modules loaded, ` +
       `${report.nativeStack.length} native frames`);
});

test('console: terminal', () => {
  note(`stdout ${process.stdout.isTTY ? `is a ${process.stdout.columns}x${process.stdout.rows} TTY` :
                                         'is not a TTY'}, ` +
       `stdin ${process.stdin.isTTY ? 'is' : 'is not'} a TTY`);
});

// ---------------------------------------------------------------------------
// Only with --net: these need the internet, and say more about the machine's
// certificates, clock and connection than about this build.
// ---------------------------------------------------------------------------

test('net (external): DNS resolution', async () => {
  if (!WITH_NET) skip('pass --net to run');
  const result = await require('node:dns').promises.lookup('nodejs.org');
  assert.ok(result.address);
  note(result.address);
});

test('net (external): HTTPS request', async () => {
  if (!WITH_NET) skip('pass --net to run');
  const response = await fetch('https://nodejs.org/dist/index.json');
  assert.strictEqual(response.status, 200);
  const list = await response.json();
  assert.ok(Array.isArray(list) && list.length > 0);
  note(`newest release listed: ${list[0].version}`);
});

// ---------------------------------------------------------------------------
// The runner
// ---------------------------------------------------------------------------

function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out after ${ms / 1000} s`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function main() {
  const selected = ONLY ?
      tests.filter((t) => t.name.toLowerCase().includes(ONLY.toLowerCase())) : tests;

  if (flag('list')) {
    for (const t of selected) console.log(t.name);
    return 0;
  }

  console.log(`Node ${process.version} ${process.arch} on ${os.type()} ${os.release()}`);
  console.log(`${process.execPath}`);
  console.log('');

  const counts = { PASS: 0, FAIL: 0, SKIP: 0 };
  const failures = [];
  const width = Math.max(...selected.map((t) => t.name.length), 10);

  for (const t of selected) {
    notes = [];
    let outcome = 'PASS';
    let detail = '';
    const started = Date.now();
    // The name goes out before the test runs, so that if node.exe dies
    // outright the last line on the screen names the test that killed it.
    process.stdout.write(`  ${t.name.padEnd(width)}  `);
    try {
      await withTimeout(Promise.resolve().then(t.fn), TEST_TIMEOUT_MS);
    } catch (error) {
      if (error instanceof Skip) {
        outcome = 'SKIP';
        detail = error.message;
      } else {
        outcome = 'FAIL';
        detail = (error && error.message) ? error.message.split('\n')[0] : String(error);
        failures.push({ name: t.name, error });
      }
    }
    counts[outcome]++;
    const took = Date.now() - started;
    console.log(`${outcome}${took >= 1000 ? ` (${(took / 1000).toFixed(1)} s)` : ''}`);
    if (detail) console.log(`      ${detail}`);
    for (const n of notes) console.log(`      ${n}`);
  }

  if (scratch) {
    try {
      fs.rmSync(scratch, { recursive: true, force: true });
    } catch (error) {
      console.log(`\n  (could not remove ${scratch}: ${error.code})`);
    }
  }

  console.log('');
  console.log(`${counts.PASS} passed, ${counts.FAIL} failed, ${counts.SKIP} skipped`);
  if (failures.length) {
    console.log('');
    console.log('Failed:');
    for (const f of failures) {
      console.log(`  ${f.name}`);
      if (VERBOSE && f.error && f.error.stack) {
        console.log(f.error.stack.split('\n').map((l) => '      ' + l).join('\n'));
      }
    }
    if (!VERBOSE) console.log('\nRe-run with --verbose for stack traces.');
  }
  return counts.FAIL;
}

// An error nothing caught would otherwise end the run with a stack trace and
// no summary. Report it as what it is and keep the exit code honest.
process.on('uncaughtException', (error) => {
  console.log(`\n\nUNCAUGHT: ${error && error.stack ? error.stack : error}`);
  process.exit(100);
});

main().then((failed) => {
  // Not process.exit(): let pending output flush, which matters when stdout
  // is a pipe on Windows.
  process.exitCode = failed;
});

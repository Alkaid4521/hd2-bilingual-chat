'use strict';
// HD2BilingualChat transport helper.  Started once by the game (BilingualChat.lua) and kept
// alive for the whole session, so every translation reuses one TLS connection instead of
// spawning curl.exe and handshaking again for each chat line.
//
//   node hd2bc_helper.js <dir>
//
// <dir> holds, all files owned by one side each:
//   helper.cfg   in   url=, token=, idle=<ms>, warm=<0|1>          written by the mod
//   helper.ready out  "<pid> node <version>"                       written once at startup
//   job.tmp      in   staging file, renamed to job.json to publish (never read)
//   job.json     in   {"id":"<pid>-<n>","body":"<raw request body>"}
//   raw.txt      out  the API response body, exactly as received
//   out.txt      out  id=, ok=, ms=, reused=, status=, err=
//   helper.log   out  the helper's own trace, for diagnosing a silent transport
const fs = require('fs');
const path = require('path');
const https = require('https');

const DIR = process.argv[2] || '.';
const P = function (name) { return path.join(DIR, name); };
const sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };

function log(line) {
  try { fs.appendFileSync(P('helper.log'), new Date().toISOString() + ' ' + line + '\n'); } catch (e) {}
}

// the mod polls out.txt, so raw.txt must be complete before out.txt appears: rename, not write
function atomic(file, data) {
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

function read_cfg() {
  let raw;
  try { raw = fs.readFileSync(P('helper.cfg'), 'utf8'); } catch (e) { return null; }
  raw = raw.replace(/^\uFEFF/, '');
  const out = {};
  for (const line of raw.split(/\r?\n/)) {
    const at = line.indexOf('=');
    if (at > 0) out[line.slice(0, at).trim()] = line.slice(at + 1);
  }
  return out.url ? out : null;
}

const endpoint = function (url, tail) { return url.replace(/[\/\s]+$/, '') + tail; };
const agent = new https.Agent({ keepAlive: true, maxSockets: 1, maxFreeSockets: 1, keepAliveMsecs: 60000 });
const sockets = new WeakSet();

// reused=1 proves the connection survived: that is the whole point of this process
function call(url, method, body, token) {
  return new Promise(function (resolve) {
    const started = Date.now();
    let reused = -1;
    let target;
    try { target = new URL(url); } catch (e) {
      resolve({ status: 0, body: '', reused: reused, ms: 0, err: 'bad_url' });
      return;
    }
    const headers = { accept: 'application/json', 'content-type': 'application/json' };
    if (token) headers.authorization = 'Bearer ' + token;
    if (body) headers['content-length'] = Buffer.byteLength(body);
    const req = https.request({
      hostname: target.hostname, port: target.port || 443,
      path: target.pathname + target.search, method: method, agent: agent, headers: headers
    }, function (res) {
      const chunks = [];
      res.on('data', function (c) { chunks.push(c); });
      res.on('end', function () {
        resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8'),
          reused: reused, ms: Date.now() - started, err: '' });
      });
    });
    req.on('socket', function (s) { reused = sockets.has(s) ? 1 : 0; sockets.add(s); });
    req.on('error', function (e) {
      resolve({ status: 0, body: '', reused: reused, ms: Date.now() - started,
        err: String((e && e.message) || e).replace(/\s+/g, '_') });
    });
    req.setTimeout(45000, function () { req.destroy(new Error('timeout')); });
    if (body) req.write(body);
    req.end();
  });
}

(async function main() {
  for (const name of ['job.json', 'job.taken.json', 'out.txt', 'raw.txt']) {
    try { fs.unlinkSync(P(name)); } catch (e) {}
  }
  try { fs.writeFileSync(P('helper.log'), ''); } catch (e) {}
  atomic(P('helper.ready'), process.pid + ' node ' + process.version + '\n');
  log('ready pid=' + process.pid + ' node=' + process.version + ' ppid=' + process.ppid);

  let last = Date.now();
  let warm_at = 0;
  let lost_parent = 0;
  for (;;) {
    await sleep(50);
    const cfg = read_cfg();
    const idle = Number(cfg && cfg.idle) || 900000;
    if (Date.now() - last > idle) {
      log('idle exit after ' + Math.round((Date.now() - last) / 1000) + 's');
      try { fs.unlinkSync(P('helper.ready')); } catch (e) {}
      process.exit(0);
    }
    // the game closing must not leave a stray process behind
    try { process.kill(process.ppid, 0); lost_parent = 0; } catch (e) { lost_parent += 1; }
    if (lost_parent >= 2) {
      log('parent ' + process.ppid + ' gone, exit');
      try { fs.unlinkSync(P('helper.ready')); } catch (e) {}
      process.exit(0);
    }
    // keep the connection genuinely warm between chat lines; /models costs no tokens
    if (cfg && cfg.warm !== '0' && Date.now() - warm_at > 45000 && Date.now() - last > 3000) {
      warm_at = Date.now();
      last = Date.now();
      call(endpoint(cfg.url, '/models'), 'GET', null, cfg.token).then(function (r) {
        log('warm status=' + r.status + ' reused=' + r.reused + ' ms=' + r.ms + ' ' + r.err);
      });
    }

    try { fs.renameSync(P('job.json'), P('job.taken.json')); } catch (e) {
      if (e.code !== 'ENOENT') log('take failed ' + e.code);
    }
    if (fs.existsSync(P('job.taken.json'))) {
      let job = null;
      try { job = JSON.parse(fs.readFileSync(P('job.taken.json'), 'utf8').replace(/^\uFEFF/, '')); } catch (e) {
        log('job parse failed: ' + String(e.message));
      }
      try { fs.unlinkSync(P('job.taken.json')); } catch (e) {}
      if (job && job.id) {
        const started = Date.now();
        const url = endpoint((cfg && cfg.url) || '', '/chat/completions');
        const res = cfg ? await call(url, 'POST', String(job.body || ''), cfg.token)
          : { status: 0, body: '', reused: -1, ms: 0, err: 'no_cfg' };
        if (res.body) atomic(P('raw.txt'), res.body);
        atomic(P('out.txt'), 'id=' + job.id + '\nok=' + ((res.err || !res.body) ? 0 : 1)
          + '\nms=' + res.ms + '\nreused=' + res.reused + '\nstatus=' + res.status
          + '\nerr=' + (res.err || '') + '\n');
        log('job id=' + job.id + ' status=' + res.status + ' ms=' + res.ms + ' reused=' + res.reused
          + ' bytes=' + res.body.length + ' total=' + (Date.now() - started) + (res.err ? ' err=' + res.err : ''));
      }
      last = Date.now();
    }
  }
})();

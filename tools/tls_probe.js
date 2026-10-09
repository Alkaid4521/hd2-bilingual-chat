'use strict';
// measures what the transport costs, so the helper can be judged on numbers instead of a hunch:
//   cold = new agent per request (what curl.exe does every message: DNS + TCP + TLS + close)
//   warm = one keep-alive agent for all requests (what the helper does)
const https = require('https');
const token = process.argv[2];
const base = process.argv[3];
const seen = new WeakSet();

function probe(agent, label) {
  return new Promise(function (resolve) {
    const t0 = Date.now();
    let reused = -1;
    const req = https.request({
      hostname: new URL(base).hostname, path: '/v1/models', method: 'GET',
      headers: { authorization: 'Bearer ' + token, accept: 'application/json' }, agent: agent
    }, function (res) {
      res.resume();
      res.on('end', function () {
        console.log(label + ' status=' + res.statusCode + ' total=' + (Date.now() - t0)
          + 'ms reused=' + reused);
        resolve();
      });
    });
    req.on('socket', function (s) { reused = seen.has(s) ? 1 : 0; seen.add(s); });
    req.on('error', function (e) { console.log(label + ' error=' + e.message); resolve(); });
    req.end();
  });
}

(async function () {
  for (let i = 1; i <= 3; i++) {
    await probe(new https.Agent({ keepAlive: false }), 'cold' + i);
  }
  const keep = new https.Agent({ keepAlive: true, maxSockets: 1 });
  for (let i = 1; i <= 4; i++) {
    await probe(keep, 'warm' + i);
    await new Promise(function (r) { setTimeout(r, 300); });
  }
})();

'use strict';
// Which request shape stops the model from spending reasoning tokens on a one-line translation?
// Prints wall time, completion tokens, reasoning tokens and the answer for every candidate.
const https = require('https');
const token = process.argv[2];
const base = process.argv[3];
const models = (process.argv[4] || 'deepseek-flash').split(',');

const variants = [
  { name: 'baseline', extra: {} },
  { name: 'thinking_type', extra: { thinking: { type: 'disabled' } } },
  { name: 'tpl_kwargs', extra: { chat_template_kwargs: { thinking: false } } },
  { name: 'effort_none', extra: { reasoning_effort: 'none' } },
  { name: 'enable_thinking', extra: { enable_thinking: false } }
];
const samples = ['hello', 'need backup on the left flank, three bugs coming'];
const agent = new https.Agent({ keepAlive: true, maxSockets: 1, timeout: 60000 });

function ask(model, variant, source) {
  const body = JSON.stringify(Object.assign({
    model: model,
    messages: [
      { role: 'system', content: 'You translate video game chat. Answer with the translation only, no quotes and no explanation.' },
      { role: 'user', content: 'Translate this Helldivers 2 chat line into Simplified Chinese:\n' + source }
    ],
    temperature: 0.2, max_tokens: 200, stream: false
  }, variant.extra));
  return new Promise(function (resolve) {
    const t0 = Date.now();
    const req = https.request({
      hostname: new URL(base).hostname, path: '/v1/chat/completions', method: 'POST', agent: agent,
      headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json',
        'content-length': Buffer.byteLength(body) }
    }, function (res) {
      const chunks = [];
      res.on('data', function (c) { chunks.push(c); });
      res.on('end', function () {
        const text = Buffer.concat(chunks).toString('utf8');
        let usage = {}, content = '', err = '';
        try {
          const j = JSON.parse(text);
          usage = j.usage || {};
          content = ((j.choices || [])[0] || {}).message || {};
          content = content.content || '';
          if (j.error) err = 'api:' + (j.error.message || JSON.stringify(j.error));
        } catch (e) { err = 'parse:' + text.slice(0, 80); }
        resolve({ ms: Date.now() - t0, wall: Date.now() - t0, status: res.statusCode,
          ct: usage.completion_tokens, rt: (usage.completion_tokens_details || {}).reasoning_tokens,
          content: content.replace(/\s+/g, ' ').slice(0, 40), err: err });
      });
    });
    req.on('error', function (e) { resolve({ ms: Date.now() - t0, err: 'net:' + e.message }); });
    req.end(body);
  });
}

(async function () {
  for (const model of models) {
    for (const variant of variants) {
      for (const sample of samples) {
        const r = await ask(model, variant, sample);
        console.log([model, variant.name, 'ms=' + r.ms, 'status=' + r.status,
          'ct=' + r.ct, 'rt=' + r.rt, '"' + r.content + '"', r.err].join(' '));
      }
    }
  }
})();

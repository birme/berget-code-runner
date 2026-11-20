// Stub deploy-manager: POST /myagents/tasks/:id/github-token
// STUB_MODE: ok | 500 | 401 | inactive
const http = require('http');
const mode = process.env.STUB_MODE || 'ok';
const srv = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const okRoute = req.method === 'POST' && /^\/myagents\/tasks\/[^/]+\/github-token$/.test(req.url);
    const nonce = req.headers['x-osc-run-nonce'];
    const send = (code, obj) => {
      res.writeHead(code, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(obj));
    };
    if (!okRoute) return send(404, { message: 'not found' });
    let parsed = {};
    try { parsed = JSON.parse(body); } catch (e) { return send(400, { message: 'bad body' }); }
    if (Object.keys(parsed).sort().join() !== 'runId,tenantId') return send(400, { message: 'bad body' });
    if (mode === '401' || nonce !== 'nonce-123') return send(401, { message: 'unauthorized' });
    if (mode === '500') return send(500, { message: 'boom' });
    if (mode === 'inactive') return send(409, { message: 'Run is no longer active' });
    send(200, { token: 'ghs_FRESHTOKEN', expiresAt: '2030-01-01T00:00:00Z' });
  });
});
srv.listen(0, '127.0.0.1', () => console.log(srv.address().port));

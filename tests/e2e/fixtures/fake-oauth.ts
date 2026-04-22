import { createServer, type Server, type IncomingMessage, type ServerResponse } from 'node:http';
import { AddressInfo } from 'node:net';

// Phase 11 plan 06 — minimal OAuth token + revoke endpoint stand-in.
//
// Wails AuthManager calls token endpoint for refresh and revoke endpoint at
// SignOut. The harness rarely needs to exercise refresh (the fake token JSON
// already has a far-future expiry) but a 200 default keeps any unexpected
// refresh call from blowing up the test.

export interface FakeOAuthControl {
  baseURL: string;
  tokenURL: string;
  revokeURL: string;
  port: number;
  refreshCalls: number;
  revokeCalls: number;
  failRefreshNextWith(status: number, errorBody?: string): void;
  reset(): void;
  close(): Promise<void>;
}

export async function startFakeOAuth(): Promise<FakeOAuthControl> {
  let refreshCalls = 0;
  let revokeCalls = 0;
  const refreshOverrides: { status: number; body: string }[] = [];

  const handler = async (req: IncomingMessage, res: ServerResponse) => {
    const chunks: Buffer[] = [];
    req.on('data', (chunk: Buffer) => chunks.push(chunk));
    await new Promise<void>((resolve) => req.on('end', () => resolve()));

    const url = req.url ?? '';
    const method = req.method ?? '';

    if (method === 'POST' && url.endsWith('/token')) {
      refreshCalls++;
      const override = refreshOverrides.shift();
      if (override !== undefined) {
        res.statusCode = override.status;
        res.setHeader('Content-Type', 'application/json');
        res.end(override.body);
        return;
      }
      res.statusCode = 200;
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({
        access_token: 'e2e-fake-access-refreshed',
        expires_in: 3600,
        token_type: 'Bearer',
      }));
      return;
    }

    if (method === 'POST' && url.endsWith('/revoke')) {
      revokeCalls++;
      res.statusCode = 200;
      res.end('');
      return;
    }

    res.statusCode = 404;
    res.end(`fake-oauth: no route for ${method} ${url}`);
  };

  const server: Server = createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', () => resolve()));
  const addr = server.address() as AddressInfo;
  const port = addr.port;
  const baseURL = `http://127.0.0.1:${port}`;

  return {
    baseURL,
    tokenURL: `${baseURL}/token`,
    revokeURL: `${baseURL}/revoke`,
    port,
    get refreshCalls() { return refreshCalls; },
    get revokeCalls() { return revokeCalls; },
    failRefreshNextWith(status: number, errorBody = '{"error":"invalid_grant"}') {
      refreshOverrides.push({ status, body: errorBody });
    },
    reset() {
      refreshCalls = 0;
      revokeCalls = 0;
      refreshOverrides.length = 0;
    },
    async close() {
      await new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      });
    },
  };
}

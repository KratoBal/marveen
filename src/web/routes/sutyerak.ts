// Sutyerák door: the Acropora OS backend reaches the assistant gateway
// (sutyerak/gateway.py, loopback only) through the dashboard's port, which
// the host publishes on its tailscale address alone (measured 2026-10-02: the
// production API container reaches 100.117.177.56:3420, the private 10.20.0.2
// address is refused). A second published port would need a container
// recreate; this path needs none.
//
// NOT under /api/: the dashboard token must never be handed to the OS. The
// gateway authenticates the caller itself (its own shared secret), so this
// route forwards the Authorization header untouched and adds nothing. It
// streams the NDJSON answer through without buffering.

import http from 'node:http'
import type { RouteContext } from './types.js'

const PREFIX = '/sutyerak/'
const ALLOWED = new Set(['POST /sutyerak/ask', 'GET /sutyerak/health'])
const BODY_MAX_BYTES = 20 * 1024

export function sutyerakGatewayPort(): number {
  const raw = Number(process.env.SUTYERAK_GATEWAY_PORT)
  return Number.isInteger(raw) && raw > 0 ? raw : 3430
}

export async function tryHandleSutyerak(ctx: RouteContext): Promise<boolean> {
  const { req, res, path, method } = ctx
  if (!path.startsWith(PREFIX)) return false
  if (!ALLOWED.has(`${method} ${path}`)) {
    res.writeHead(404, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ error: 'not found' }))
    return true
  }
  const declared = Number(req.headers['content-length'] ?? 0)
  if (declared > BODY_MAX_BYTES) {
    res.writeHead(413, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ error: 'too large' }))
    return true
  }

  await new Promise<void>((resolve) => {
    const upstream = http.request(
      {
        host: '127.0.0.1',
        port: sutyerakGatewayPort(),
        method,
        path: path.slice('/sutyerak'.length),
        headers: {
          ...(req.headers['content-type'] ? { 'content-type': req.headers['content-type'] } : {}),
          ...(req.headers['content-length'] ? { 'content-length': req.headers['content-length'] } : {}),
          ...(req.headers.authorization ? { authorization: req.headers.authorization } : {}),
        },
        timeout: 300_000,
      },
      (up) => {
        res.writeHead(up.statusCode ?? 502, {
          'Content-Type': up.headers['content-type'] ?? 'application/json',
          'Cache-Control': 'no-store',
        })
        up.pipe(res)
        up.on('end', resolve)
        up.on('error', () => { res.end(); resolve() })
      },
    )
    upstream.on('timeout', () => upstream.destroy(new Error('timeout')))
    upstream.on('error', () => {
      if (!res.headersSent) {
        res.writeHead(502, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ error: 'sutyerak gateway unavailable' }))
      } else {
        res.end()
      }
      resolve()
    })
    let received = 0
    req.on('data', (chunk: Buffer) => {
      received += chunk.length
      if (received > BODY_MAX_BYTES) {
        upstream.destroy(new Error('body too large'))
        req.destroy()
        return
      }
      upstream.write(chunk)
    })
    req.on('end', () => upstream.end())
    req.on('error', () => upstream.destroy())
  })
  return true
}

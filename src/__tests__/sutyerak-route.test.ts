import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest'
import http from 'node:http'
import type { AddressInfo } from 'node:net'
import { tryHandleSutyerak } from '../web/routes/sutyerak.js'

// The route is the OS backend's only way to the assistant gateway. It must
// forward exactly the gateway's own surface (ask + health), pass the caller's
// Authorization through untouched (the gateway checks it, the dashboard does
// not), drop everything else the caller sends, and stream the answer.

let upstream: http.Server
let front: http.Server
let seen: { method?: string; url?: string; headers?: http.IncomingHttpHeaders; body?: string }[] = []

function listen(server: http.Server): Promise<number> {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve((server.address() as AddressInfo).port)))
}

function request(port: number, method: string, path: string, body?: string, headers: Record<string, string> = {}) {
  return new Promise<{ status: number; body: string }>((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port, method, path, headers }, (res) => {
      let data = ''
      res.on('data', (c) => (data += c))
      res.on('end', () => resolve({ status: res.statusCode ?? 0, body: data }))
    })
    r.on('error', reject)
    if (body) r.write(body)
    r.end()
  })
}

let frontPort = 0

beforeAll(async () => {
  upstream = http.createServer((req, res) => {
    let body = ''
    req.on('data', (c) => (body += c))
    req.on('end', () => {
      seen.push({ method: req.method, url: req.url, headers: req.headers, body })
      res.writeHead(200, { 'Content-Type': 'application/x-ndjson' })
      res.write('{"type":"text","delta":"szia"}\n')
      setTimeout(() => res.end('{"type":"done"}\n'), 20)
    })
  })
  process.env.SUTYERAK_GATEWAY_PORT = String(await listen(upstream))
  front = http.createServer(async (req, res) => {
    const url = new URL(req.url || '/', 'http://localhost')
    const handled = await tryHandleSutyerak({ req, res, path: url.pathname, method: req.method || 'GET', url })
    if (!handled) { res.writeHead(418); res.end('not mine') }
  })
  frontPort = await listen(front)
})

afterEach(() => { seen = [] })

afterAll(() => {
  upstream.close()
  front.close()
  delete process.env.SUTYERAK_GATEWAY_PORT
})

describe('sutyerak route', () => {
  it('forwards POST /sutyerak/ask to /ask with the Authorization header and streams the answer', async () => {
    const r = await request(frontPort, 'POST', '/sutyerak/ask', '{"question":"x"}', {
      'Content-Type': 'application/json',
      Authorization: 'Bearer gateway-secret',
      Cookie: 'mv_session=abc',
      'X-Forwarded-For': '1.2.3.4',
    })
    expect(r.status).toBe(200)
    expect(r.body).toBe('{"type":"text","delta":"szia"}\n{"type":"done"}\n')
    expect(seen).toHaveLength(1)
    expect(seen[0]!.url).toBe('/ask')
    expect(seen[0]!.method).toBe('POST')
    expect(seen[0]!.body).toBe('{"question":"x"}')
    expect(seen[0]!.headers!.authorization).toBe('Bearer gateway-secret')
    // nothing else the caller sent reaches the gateway
    expect(seen[0]!.headers!.cookie).toBeUndefined()
    expect(seen[0]!.headers!['x-forwarded-for']).toBeUndefined()
  })

  it('forwards GET /sutyerak/health', async () => {
    const r = await request(frontPort, 'GET', '/sutyerak/health')
    expect(r.status).toBe(200)
    expect(seen[0]!.url).toBe('/health')
  })

  it('refuses any other path or method under the prefix without calling the gateway', async () => {
    for (const [method, path] of [['GET', '/sutyerak/ask'], ['POST', '/sutyerak/admin'], ['DELETE', '/sutyerak/ask']] as const) {
      const r = await request(frontPort, method, path)
      expect(r.status, `${method} ${path}`).toBe(404)
    }
    expect(seen).toHaveLength(0)
  })

  it('leaves every other path to the next handler, including a dot-segment escape', async () => {
    // the URL parser normalizes /sutyerak/../api/kanban to /api/kanban, so it
    // is never forwarded: it reaches the dashboard's own /api/ auth gate
    for (const path of ['/api/kanban', '/sutyerak/../api/kanban']) {
      const r = await request(frontPort, 'POST', path)
      expect(r.status, path).toBe(418)
    }
    expect(seen).toHaveLength(0)
  })

  it('refuses an oversized body', async () => {
    const big = 'x'.repeat(21 * 1024)
    const r = await request(frontPort, 'POST', '/sutyerak/ask', big, { 'Content-Length': String(big.length) })
    expect(r.status).toBe(413)
    expect(seen).toHaveLength(0)
  })

  it('answers 502 when the gateway is down', async () => {
    const saved = process.env.SUTYERAK_GATEWAY_PORT
    process.env.SUTYERAK_GATEWAY_PORT = '1'
    try {
      const r = await request(frontPort, 'GET', '/sutyerak/health')
      expect(r.status).toBe(502)
    } finally {
      process.env.SUTYERAK_GATEWAY_PORT = saved
    }
  })
})

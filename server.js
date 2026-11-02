const http = require('http')
const fs = require('fs')
const path = require('path')

const rootDir = __dirname
const port = Number(process.env.PORT || 3001)

const mimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8'
}

function sendJson(res, status, payload) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'access-control-allow-origin': '*'
  })
  res.end(JSON.stringify(payload))
}

function serveStatic(req, res, pathname) {
  const relativePath = pathname === '/' ? '/index.html' : pathname
  const requestedPath = path.normalize(decodeURIComponent(relativePath)).replace(/^(\.\.[/\\])+/, '')
  const filePath = path.join(rootDir, requestedPath)

  if (!filePath.startsWith(rootDir)) {
    sendJson(res, 403, { error: 'Forbidden' })
    return
  }

  fs.readFile(filePath, (err, content) => {
    if (err) {
      if (err.code === 'ENOENT') {
        sendJson(res, 404, { error: 'Not Found' })
      } else {
        sendJson(res, 500, { error: 'Server Error' })
      }
      return
    }

    const ext = path.extname(filePath).toLowerCase()
    res.writeHead(200, {
      'content-type': mimeTypes[ext] || 'application/octet-stream',
      'cache-control': 'no-cache'
    })
    res.end(content)
  })
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`)
  serveStatic(req, res, url.pathname)
})

server.listen(port, () => {
  console.log(`Luce Chapel Bible Reading Stat Server running at http://127.0.0.1:${port}/`)
})

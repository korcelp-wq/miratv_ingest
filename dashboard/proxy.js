const http = require('http');
const https = require('https');

const PORT = 8889;
const TOKEN = 'WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY';

const server = http.createServer((req, res) => {
    // Enable CORS for all responses
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    // Handle preflight requests
    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }

    // Serve static files for root
    if (req.method === 'GET' && req.url === '/') {
        req.url = '/index.html';
    }

    // Handle CVI proxy endpoint
    if (req.url === '/cvi' && req.method === 'POST') {
        let body = '';
        
        req.on('data', chunk => {
            body += chunk.toString();
        });
        
        req.on('end', () => {
            const options = {
                hostname: 'miratv.club',
                path: '/_workers/api/series/dog_open.php?token=' + TOKEN,
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(body)
                }
            };
            
            const proxyReq = https.request(options, (proxyRes) => {
                res.writeHead(proxyRes.statusCode, {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                });
                
                proxyRes.pipe(res);
            });
            
            proxyReq.on('error', (error) => {
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: error.message }));
            });
            
            proxyReq.write(body);
            proxyReq.end();
        });
        
        return;
    }
    
    // Serve static files
    const fs = require('fs');
    const path = require('path');
    
    let filePath = path.join(__dirname, req.url);
    
    fs.readFile(filePath, (err, data) => {
        if (err) {
            res.writeHead(404);
            res.end('File not found');
            return;
        }
        
        const ext = path.extname(filePath);
        const contentType = {
            '.html': 'text/html',
            '.json': 'application/json',
            '.js': 'application/javascript',
            '.css': 'text/css'
        }[ext] || 'text/plain';
        
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(data);
    });
});

server.listen(PORT, () => {
    console.log(`✅ Proxy running at http://localhost:${PORT}/`);
});
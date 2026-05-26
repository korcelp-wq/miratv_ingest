from http.server import HTTPServer, SimpleHTTPRequestHandler
import urllib.request
import json
import urllib.parse

class CVIProxy(SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/cvi':
            # Read the request body
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            
            # Forward to dog_open.php with token in URL
            url = 'https://miratv.club/_workers/api/series/dog_open.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY'
            
            # Create request
            req = urllib.request.Request(url, data=post_data, method='POST')
            req.add_header('Content-Type', 'application/json')
            
            try:
                # Forward the request
                with urllib.request.urlopen(req) as response:
                    response_data = response.read()
                    
                    # Send back the response
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(response_data)
            except Exception as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'error': str(e)}).encode())
        else:
            # Serve static files normally
            super().do_GET()

if __name__ == '__main__':
    server = HTTPServer(('localhost', 8889), CVIProxy)
    print('Proxy server running at http://localhost:8889')
    print('Press Ctrl+C to stop')
    server.serve_forever()
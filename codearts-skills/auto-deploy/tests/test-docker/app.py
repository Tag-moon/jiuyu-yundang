import http.server
import json
import os
import socketserver

PORT = int(os.environ.get("PORT", "8080"))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok"}).encode())


with socketserver.TCPServer(("", PORT), Handler) as httpd:
    httpd.serve_forever()

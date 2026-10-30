import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8899


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._json({"object": "list", "data": [
                {"id": "mock-alpha", "object": "model"},
                {"id": "mock-beta", "object": "model"},
                {"id": "mock-gamma", "object": "model"},
            ]})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw)
        except Exception:
            req = {}
        model = req.get("model", "mock-beta")
        user = ""
        for m in req.get("messages", []):
            if m.get("role") == "user":
                user = m.get("content", "")
        if "只回复两个字" in user:
            content = "可用"
        else:
            payload = {
                "summary": "卡诺循环是在两个热源之间由等温与绝热过程组成的理想循环。",
                "concepts": ["卡诺循环", "等温过程", "绝热过程", "热机效率"],
                "tags": ["热力学", "循环过程"],
            }
            content = json.dumps(payload, ensure_ascii=False)
        self._json({
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": content},
                         "finish_reason": "stop"}],
        })


if __name__ == "__main__":
    print("mock on 0.0.0.0:%d" % PORT, flush=True)
    HTTPServer(("0.0.0.0", PORT), H).serve_forever()

#!/usr/bin/env python3
"""A stand-in for the Messages API, so a scratch Claude Code runs without a login.

Usage: mock_api.py PORT LOG

Every POST to /v1/messages is appended to LOG (one JSON line: the request body). The reply is plain text, streamed when
asked: "ACK: <marker>" when what came after the last assistant turn carries a VSTEST marker (a hook's text reached the model),
else "Turn one finished.". Anything else gets an empty JSON object.
"""
import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG = int(sys.argv[1]), sys.argv[2]
lock = threading.Lock()


def texts(content):
    if isinstance(content, str):
        return [content]
    out = []
    for block in content or []:
        if block.get("type") == "text":
            out.append(block.get("text", ""))
        elif block.get("type") == "tool_result":
            out.extend(texts(block.get("content")))
    return out


def reply_for(body):
    messages = body.get("messages") or []
    since = []
    for message in reversed(messages):
        if message.get("role") == "assistant":
            break
        since.extend(texts(message.get("content")))
    found = re.findall(r"VSTEST-[A-Za-z0-9-]+", "\n".join(since))
    return "ACK: " + found[-1] if found else "Turn one finished."


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_json({})

    def send_json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length)
        path = self.path.split("?")[0]
        if path.endswith("/count_tokens"):
            return self.send_json({"input_tokens": 10})
        if not path.endswith("/v1/messages"):
            return self.send_json({})
        body = json.loads(raw or b"{}")
        with lock, open(LOG, "a") as log:
            log.write(json.dumps(body) + "\n")
        text = reply_for(body)
        model = body.get("model", "claude-mock")
        usage = {"input_tokens": 10, "output_tokens": 5}
        message = {"id": "msg_mock", "type": "message", "role": "assistant", "model": model,
                   "stop_reason": "end_turn", "stop_sequence": None, "usage": usage}
        if not body.get("stream"):
            return self.send_json({**message, "content": [{"type": "text", "text": text}]})
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        events = [
            ("message_start", {"type": "message_start", "message": {**message, "content": [], "stop_reason": None}}),
            ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                               "usage": {"output_tokens": 5}}),
            ("message_stop", {"type": "message_stop"}),
        ]
        for name, data in events:
            self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
        self.wfile.flush()


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

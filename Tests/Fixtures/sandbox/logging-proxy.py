"""A stand-in for the node's egress proxy, for measuring which hosts a program in a box asks for (the session sandbox
plan's SB0, Step 3). Nothing in the product runs it.

    python3 -I logging-proxy.py PORT_FILE LOG_FILE

Listens on 127.0.0.1 on a port the kernel picks, writes that port to PORT_FILE (a temporary file renamed into place),
and serves until it is killed. Each request is one line of LOG_FILE, flushed: "CONNECT host:port" for a tunnel, then
carried both ways as it is (the bytes are never read, logged or kept), or "HTTP host:port METHOD" for plain HTTP, which
is answered 403 and not carried. It refuses nothing else: it logs, it doesn't judge.
"""

import os
import socket
import sys
import threading

port_file, log_file = sys.argv[1], sys.argv[2]
log_lock = threading.Lock()


def log(line):
    with log_lock, open(log_file, "a") as out:
        out.write(line + "\n")


def pump(source, sink):
    try:
        while True:
            chunk = source.recv(65536)
            if not chunk:
                break
            sink.sendall(chunk)
    except OSError:
        pass
    finally:
        for end in (source, sink):
            try:
                end.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve(client):
    try:
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 65536:
            chunk = client.recv(4096)
            if not chunk:
                return
            head += chunk
        request = head.split(b"\r\n", 1)[0].decode("latin-1")
        method, target = (request.split(" ") + ["", ""])[:2]
        if method == "CONNECT":
            host, _, port = target.rpartition(":")
            log("CONNECT %s" % target)
            upstream = socket.create_connection((host, int(port or 443)), timeout=30)
            upstream.settimeout(None)
            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            rest = head.split(b"\r\n\r\n", 1)[1]
            if rest:
                upstream.sendall(rest)
            other = threading.Thread(target=pump, args=(upstream, client), daemon=True)
            other.start()
            pump(client, upstream)
            other.join()
        else:
            host = ""
            for line in head.split(b"\r\n")[1:]:
                if line.lower().startswith(b"host:"):
                    host = line[5:].strip().decode("latin-1")
            log("HTTP %s %s" % (host or target, method))
            client.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    except OSError as error:
        log("ERROR %s" % error.__class__.__name__)
    finally:
        client.close()


listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(64)
temporary = port_file + ".tmp"
with open(temporary, "w") as out:
    out.write("%d\n" % listener.getsockname()[1])
os.rename(temporary, port_file)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()

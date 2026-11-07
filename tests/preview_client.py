import json
import socket
import struct


class PreviewClient:
    def __init__(self, sessions, name, rows, cols):
        self.connection = socket.socket(socket.AF_UNIX)
        self.connection.settimeout(5)
        self.connection.connect(str(sessions.runtime / f"session-{name}.sock"))
        self.input = self.connection.makefile("rb")
        self.name = name
        self.size = {"rows": rows, "cols": cols}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.input.close()
        self.connection.close()

    def scroll(self, delta):
        request = json.dumps({"size": self.size, "delta": delta}).encode()
        self.connection.sendall(struct.pack("<IHH", len(request), 24, 1) + request)

    def frame(self):
        self.request_frame()
        return self.receive_frame()

    def request_frame(self):
        request = json.dumps({"name": self.name, "size": self.size}).encode()
        self.connection.sendall(struct.pack("<IHH", len(request), 18, 1) + request)

    def receive_frame(self):
        chunks = []
        while True:
            header = self.input.read(8)
            assert len(header) == 8
            length, tag, version = struct.unpack("<IHH", header)
            assert version == 1 and length <= 128 * 1024
            payload = self.input.read(length)
            assert len(payload) == length
            if tag == 11:
                assert not payload
                return b"".join(chunks)
            assert tag == 8, payload
            chunks.append(payload)

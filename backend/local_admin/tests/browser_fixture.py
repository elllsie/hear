"""Isolated browser fixture. Every cloud mutation is disabled."""
import json
import signal
import sys
import tempfile
from http.server import ThreadingHTTPServer
from pathlib import Path

from backend.local_admin.server import Application, Handler

class Fixture(Application):
    def post(self, path, data):
        if any(s in path for s in ('publish', 'rollback', 'source-rights')) or path == '/api/podcast/run':
            raise ValueError('浏览器测试环境禁止线上写入')
        return super().post(path, data)

with tempfile.TemporaryDirectory(prefix='tinghuier-browser-') as state:
    app=Fixture(state)
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    server.app=app
    info={'url':f'http://127.0.0.1:{server.server_port}', 'token':app.bootstrap, 'state':state}
    path=Path(sys.argv[1])
    path.write_text(json.dumps(info))
    path.chmod(0o600)
    print('Isolated browser fixture ready',flush=True)
    signal.signal(signal.SIGTERM,lambda *_:sys.exit(0))
    try:
        server.serve_forever()
    finally:
        app.queue.shutdown()
        server.server_close()

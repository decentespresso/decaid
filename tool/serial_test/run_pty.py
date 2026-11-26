import json
import os
import pty
import selectors
import subprocess
import sys
import threading
import tty
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse

base = Path(__file__).resolve().parent
root = base.parent.parent
config = root / '.dart_tool/package_config.json'
packages = json.loads(config.read_text())['packages']
plugin = next(p for p in packages if p['name'] == 'flutter_libserialport')
plugin_root = Path(unquote(urlparse(urljoin(config.as_uri(), plugin['rootUri'])).path))
output = root / 'build/serial-test'
output.mkdir(parents=True, exist_ok=True)
library = root / 'build/linux/x64/release/bundle/lib'
subprocess.run([
    os.environ.get('CC', 'cc'), '-shared', '-fPIC', '-DLIBSERIALPORT_ATBUILD',
    '-I', str(plugin_root / 'linux/libserialport'),
    '-I', str(plugin_root / 'third_party/libserialport'),
    str(base / 'pty_adapter.c'), '-Wl,--no-as-needed',
    '-L', str(library), '-lserialport', '-Wl,-rpath,' + str(library),
    '-o', str(output / 'pty_adapter.so'),
], check=True)
pairs = [pty.openpty(), pty.openpty()]
for master, slave in pairs:
    tty.setraw(slave)
selector = selectors.DefaultSelector()
selector.register(pairs[0][0], selectors.EVENT_READ, pairs[1][0])
selector.register(pairs[1][0], selectors.EVENT_READ, pairs[0][0])
stop = threading.Event()
def forward():
    while not stop.is_set():
        for key, _ in selector.select(0.1):
            data = os.read(key.fd, 65536)
            if data:
                while data:
                    data = data[os.write(key.data, data):]
thread = threading.Thread(target=forward, daemon=True)
thread.start()
env = dict(os.environ, LIBSERIALPORT_PATH=str(output / 'pty_adapter.so'),
           SERIAL_TEST_RX=os.ttyname(pairs[0][1]),
           SERIAL_TEST_TX=os.ttyname(pairs[1][1]))
try:
    result = subprocess.run(sys.argv[1:], env=env)
finally:
    stop.set()
    thread.join(timeout=0.2)
    selector.close()
    for master, slave in pairs:
        os.close(master)
        os.close(slave)
sys.exit(result.returncode)

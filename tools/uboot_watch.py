"""u-boot autoboot interceptor + fastboot trampoline.

Runs standalone on the GitHub Actions self-hosted runner host (aibox) — the
smoke-test workflow copies this file to /tmp/ and systemd-run's it. Talks
to the TC8 via the brainslug HTTP UART; no local /dev node needed.
"""
import os, sys, time, datetime, json, urllib.request

BRAINSLUG = os.environ.get('BRAINSLUG_HOST', '10.99.0.35')
BRAINSLUG_PORT = int(os.environ.get('BRAINSLUG_PORT', '1'))
BASE = f'http://{BRAINSLUG}/uart/{BRAINSLUG_PORT}'


class _Ser:
    """Minimal serial-like shim over the brainslug HTTP API."""
    def __init__(self):
        body = json.dumps({'baud': 115200, 'data': 8, 'parity': 0, 'stop': 1,
                           'tx_gpio': 17, 'rx_gpio': 16}).encode()
        req = urllib.request.Request(f'{BASE}/config', data=body, method='POST',
                                     headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req, timeout=5).read()

    def read(self, _n=4096):
        try:
            with urllib.request.urlopen(f'{BASE}/read', timeout=2) as r:
                return r.read()
        except Exception:
            return b''

    def write(self, data):
        req = urllib.request.Request(f'{BASE}/write', data=data, method='POST',
                                     headers={'Content-Type': 'application/octet-stream'})
        urllib.request.urlopen(req, timeout=2).read()


LOG = '/tmp/uboot-watch-' + datetime.datetime.utcnow().strftime('%Y%m%dT%H%M%SZ') + '.log'
STATE = '/tmp/uboot-watch.state'
ser = _Ser()
log = open(LOG, 'wb', buffering=0)
state = open(STATE, 'w')
state.write('STARTING\n'); state.flush()
buf = b''
phase = 'wait_uboot'
phase_t = time.time()
print('Watcher live — log:', LOG, flush=True)
while True:
    data = ser.read(4096)
    now = time.time()
    if data:
        log.write(data)
        buf += data
        if len(buf) > 16384: buf = buf[-8192:]
    if phase == 'wait_uboot' and b'Hit any key to stop autoboot' in buf:
        # Spam ^C + space for ~3s
        for _ in range(120):
            ser.write(b'\x03 \r')
            time.sleep(0.025)
        ser.read(8192)  # drain
        phase = 'at_uboot'; phase_t = now
        state.write('AT_UBOOT_PROMPT\n'); state.flush()
        buf = b''
    elif phase == 'at_uboot' and (now - phase_t) > 1.0:
        # Time-driven: send fastboot 0 (also blast extra ^C)
        ser.write(b'\r\r')
        time.sleep(0.1)
        ser.write(b'fastboot 0\r')
        time.sleep(0.5)
        ser.write(b'\r')
        phase = 'fastboot_sent'; phase_t = now
        state.write('FASTBOOT_CMD_SENT\n'); state.flush()
        buf = b''
    elif phase == 'fastboot_sent':
        # Look for fastboot listening or USB enum
        if b'Listening for' in buf or b'fastboot' in buf.lower() or (now - phase_t) > 8.0:
            state.write('IN_FASTBOOT_MODE\n'); state.flush()
            phase = 'idle'; phase_t = now
    time.sleep(0.05)

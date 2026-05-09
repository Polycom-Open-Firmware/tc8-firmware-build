import serial, sys, time, os, datetime
LOG = '/tmp/uboot-watch-' + datetime.datetime.utcnow().strftime('%Y%m%dT%H%M%SZ') + '.log'
STATE = '/tmp/uboot-watch.state'
ser = serial.Serial('/dev/ttyUSB0', 115200, timeout=0.05)
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

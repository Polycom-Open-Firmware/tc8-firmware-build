#!/usr/bin/env python3
"""catch_uboot.py — drive a TC8 panel into u-boot via the brainslug UART.

Threaded version: starts a Ctrl-C spammer at t=0 so we don't lose the
autoboot interrupt window to HTTP setup latency. Reader thread watches
for the `u-boot=> ` prompt with no kernel-boot markers behind it (i.e.,
panel is genuinely sitting at the prompt, not transient u-boot output
mid-flight). Once seen, kills the spammer, sends a CR, confirms.

Usage:
  catch_uboot.py --brainslug http://10.99.0.35
"""
import argparse, sys, time, urllib.request, threading

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--brainslug', required=True)
    ap.add_argument('--port', type=int, default=1)
    ap.add_argument('--total-timeout', type=int, default=180)
    args = ap.parse_args()

    base = f"{args.brainslug.rstrip('/')}/uart/{args.port}"

    def w(b):
        req = urllib.request.Request(base+'/write', data=b, method='POST',
                                     headers={'Content-Type':'application/octet-stream'})
        try: urllib.request.urlopen(req, timeout=3).read()
        except Exception: pass

    def r():
        try: return urllib.request.urlopen(base+'/read', timeout=3).read()
        except Exception: return b''

    stop = threading.Event()
    state = {'buf': b'', 'last': b''}

    def spammer():
        burst = b'\x03 \r' * 8
        while not stop.is_set():
            w(burst)
            time.sleep(0.015)

    spam_thread = threading.Thread(target=spammer, daemon=True)
    spam_thread.start()
    print('[+] spammer launched', flush=True)

    end = time.monotonic() + args.total_timeout
    last_kernel = 0.0   # last time we saw "[ N.N]" kernel-log signature
    while time.monotonic() < end:
        chunk = r()
        if chunk:
            state['buf'] = (state['buf'] + chunk)[-32768:]
            state['last'] = chunk[-300:]
            # Kernel boot markers — if any appeared in this chunk, autoboot
            # already fired this cycle. Note the time so we know to keep
            # spamming through the NEXT autoboot (panel will reset under
            # spam pressure if our chars trigger a u-boot panic… unlikely
            # but harmless).
            if b'Booting Linux on physical CPU' in chunk or b'Starting kernel' in chunk:
                last_kernel = time.monotonic()
            # Prompt detection — look at recent bytes.
            tail = state['buf'][-300:]
            if b'u-boot=> ' in tail and time.monotonic() - last_kernel > 1.0:
                # Stop spam, confirm.
                stop.set()
                spam_thread.join(timeout=1)
                time.sleep(0.4)
                r()   # drain
                w(b'\r')
                time.sleep(0.7)
                confirm = r()
                if b'u-boot=> ' in confirm or confirm.rstrip().endswith(b'=>'):
                    print('[+] u-boot prompt caught', flush=True)
                    sys.exit(0)
                # False alarm — back to spamming.
                stop.clear()
                spam_thread = threading.Thread(target=spammer, daemon=True)
                spam_thread.start()
        time.sleep(0.04)

    stop.set()
    sys.stderr.write('ERROR: never caught u-boot prompt\n')
    sys.stderr.write(f'    last tail: {state["last"]!r}\n')
    sys.exit(1)

if __name__ == '__main__':
    main()

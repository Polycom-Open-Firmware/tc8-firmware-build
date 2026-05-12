#!/usr/bin/env python3
"""catch_uboot.py — drive a TC8 panel into u-boot via the brainslug UART.

The slug's HTTP server is single-threaded, so a read-while-spam loop
starves the spammer at exactly the wrong time. This version spams
*blindly* for a generous window (covers SPL + u-boot startup + the
whole bootdelay countdown), then reads to confirm we landed at the
prompt. If not, retries with a longer spam.

Usage:
  catch_uboot.py --brainslug http://10.99.0.35
"""
import argparse, sys, time, urllib.request

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

    # SPL → u-boot startup → bootdelay countdown is ~25–30 s total on this
    # device. Spam through that whole window so the autoboot prompt never
    # gets a free `tstc() == 0` moment.
    spam_total = 35.0
    burst = b'\x03 \r' * 8

    deadline = time.monotonic() + args.total_timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        print(f'[+] attempt {attempt}: blind ^C spam for {spam_total:.0f}s', flush=True)
        spam_end = time.monotonic() + spam_total
        while time.monotonic() < spam_end:
            w(burst)
            # No sleep — let HTTP latency be the natural pacer.
        # Drain any "in-flight" output, then send CR and check for prompt.
        time.sleep(0.5)
        # Read up to a few times to flush slug's RX buffer
        captured = b''
        for _ in range(4):
            captured += r()
            time.sleep(0.1)
        w(b'\r')
        time.sleep(0.7)
        confirm = r()
        captured += confirm
        if b'u-boot=> ' in confirm or confirm.rstrip().endswith(b'=>'):
            print('[+] u-boot prompt caught', flush=True)
            sys.exit(0)
        # Look for early-boot markers we should never see if we're at prompt
        if b'Booting Linux' in captured or b'Starting kernel' in captured:
            print('[!] autoboot already fired this attempt — retrying', flush=True)
        else:
            print(f'[!] no prompt signature — confirm tail: {confirm[-200:]!r}', flush=True)
        # On the next iteration, the panel will autoboot, Linux will run for
        # a bit. Sending Ctrl-C does nothing in Linux state, so we wait for
        # another PoE cycle from the caller… but the caller already cycled.
        # Easiest recovery: trigger a reboot ourselves via Linux shell.
        # (Not yet implemented; for now we just retry — the slug spam may
        # cause the kernel to misbehave and re-reset, looping us back.)
        spam_total = min(spam_total + 10, 60)

    sys.stderr.write('ERROR: gave up catching u-boot prompt\n')
    sys.exit(1)

if __name__ == '__main__':
    main()

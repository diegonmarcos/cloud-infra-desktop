#!/usr/bin/env python3
# oom-hotkey — PASSIVE evdev watcher. Hold @KEY@ for @HOLD_MS@ ms (no release)
# → write '@SYSRQ_CHAR@' to /proc/sysrq-trigger = kernel-context OOM kill (same
# path as Alt+SysRq+F), so the kill never gets stuck behind busy/starved
# userspace. Does NOT grab devices → the key keeps working normally for
# everything; a quick chord (RCtrl+C) never fires because keyup cancels the
# timer before the hold elapses. Placeholders are substituted by
# configuration_system-protection.nix from sysprot.oom_hotkey (data-driven).
import sys, time, threading
from evdev import InputDevice, list_devices, ecodes

KEY  = ecodes.ecodes["KEY_@KEY@"]
HOLD = @HOLD_MS@ / 1000.0
CHAR = "@SYSRQ_CHAR@"

def fire():
    try:
        with open("/proc/sysrq-trigger", "w") as f:
            f.write(CHAR)
        sys.stderr.write("oom-hotkey: FIRED SysRq '%s' (kernel OOM) — %s held >= %ss\n"
                         % (CHAR, "@KEY@", HOLD))
    except Exception as e:
        sys.stderr.write("oom-hotkey: sysrq write failed: %s\n" % e)
    sys.stderr.flush()

timers = {}

def watch(dev):
    for ev in dev.read_loop():
        if ev.type != ecodes.EV_KEY or ev.code != KEY:
            continue
        if ev.value == 1:                      # key down → arm timer
            t = threading.Timer(HOLD, fire)
            t.daemon = True
            timers[dev.path] = t
            t.start()
        elif ev.value == 0:                    # key up → disarm (autorepeat=2 ignored)
            t = timers.pop(dev.path, None)
            if t:
                t.cancel()

started = 0
for path in list_devices():
    try:
        d = InputDevice(path)
        if KEY in d.capabilities().get(ecodes.EV_KEY, []):
            threading.Thread(target=watch, args=(d,), daemon=True).start()
            started += 1
            sys.stderr.write("oom-hotkey: watching %s (%s)\n" % (path, d.name))
    except Exception:
        pass
sys.stderr.write("oom-hotkey: armed on %d keyboard(s); hold @KEY@ >= @HOLD_MS@ms for kernel OOM\n" % started)
sys.stderr.flush()
while True:
    time.sleep(3600)

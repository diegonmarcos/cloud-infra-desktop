[Unit]
Description=Waydroid Android sensors HAL (IIO-backed accelerometer for auto-rotate)
Documentation=https://github.com/diegonmarcos/unix
# Needs the container (binder node + hwservicemanager) up first.
After=waydroid-container.service
PartOf=waydroid-container.service

[Service]
Type=simple
Environment=WAYDROID_SENSORS_CONF=@CONF@
# 0) BOOT-SAFETY GATE: block until the framework is fully up. The HAL must NOT be present
#    while SensorService initialises, or it deadlocks the boot (Waydroid hangs on bootanim).
ExecStartPre=/bin/sh -c 'for i in $(seq 1 @BOOTTIMEOUT@); do [ "$(@WAYDROID@ shell -- getprop @BOOTGATE@ 2>/dev/null | tr -d "\r")" = "1" ] && exit 0; sleep 1; done; echo "boot-gate timeout" >&2; exit 1'
# 1) stop the in-container stub HAL so the HIDL name is free for us to own
ExecStartPre=-@WAYDROID@ shell -- sh -c "setprop @STUBPROP@ 0; setprop ctl.stop @STUBSVC@; killall -9 @STUBPROC@ 2>/dev/null; true"
# 2) register android.hardware.sensors@1.0::ISensors/default on the binder node
ExecStart=@BINARY@ @DEVICE@
# 3) once registered, bounce the Android framework so sensorservice binds to us
ExecStartPost=-/bin/sh -c "sleep 3; @WAYDROID@ shell -- sh -c '@FWRESTART@'"
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target

# da_waydroid-sensors

A host-side **Android sensors HAL** for Waydroid, fed by the Surface Pro 8's Linux **IIO
accelerometer**, so the Android container finally has an accelerometer and **auto-rotate
works** when you physically rotate the device.

## Why

Waydroid's image (Android 13 / LineageOS 20) ships a **stub** sensors HAL: Android reports
`No Sensors on the device`, so auto-rotate (which is enabled) has nothing to read. The host
rotates fine via `iio-sensor-proxy`, but that never reaches the container. This daemon bridges
the gap.

## How

Reuses the upstream Waydroid sensors daemon (`droidian/waydroid-sensors`, GPL-3.0, by Erfan
Abdi) for the hard part — implementing `android.hardware.sensors@1.0::ISensors/default` over
`libgbinder` on `/dev/anbox-hwbinder` — and **replaces only its data source**: upstream read a
`sensorfwd` Qt daemon (not on NixOS); we read `/sys/bus/iio` directly (`src/code/SensorFW.cpp`).

| File | Origin |
|------|--------|
| `src/code/{Sensors.cpp,Sensors.h,service.cpp,hybrisbindertypes.h}` | upstream, **verbatim** |
| `src/code/SensorFW.{cpp,h}` | **rewritten** — IIO accelerometer source |
| `src/code/CMakeLists.txt`, `src/flake.nix` | ours — Nix build (libgbinder/libglibutil/glib) |

Data-driven: IIO device name, poll rate and the **mount matrix** live in `build.json`; the
engine renders them into a KEY=VALUE conf the daemon reads via `WAYDROID_SENSORS_CONF`. Nothing
is baked into the binary.

## Pipeline

```bash
./build.sh build      # nix build the daemon -> dist/ ; render dist conf
./build.sh calibrate  # live-print IIO accel (m/s^2) while you rotate — to fix the mount matrix
./build.sh run        # foreground daemon (testing)
./build.sh install    # binary + rendered user systemd unit + conf
./build.sh enable     # systemctl --user enable --now + takeover
./build.sh takeover   # stop in-container stub HAL + restart sensorservice so it binds ours
./build.sh status     # daemon + live Android sensor count
./build.sh test       # tester
```

`run`/`enable`/`takeover` need a running Waydroid session.

## Calibrating the mount matrix (one-time, per device)

`build.json → iio.mount` maps each **Android** axis to a raw IIO channel + sign. Android frame:
`+X` = screen right, `+Y` = screen top, `+Z` = out of screen; the axis pointing **up** reads
`+9.81`. Run `./build.sh calibrate`, rotate the SP8, note which raw axis tracks gravity in each
orientation, set `iio.mount` accordingly, then `./build.sh build`. The tester checks the matrix
is a valid permutation.

## Status & scope

Phase 1 exports the **accelerometer** (enough for auto-rotate). Gyroscope / magnetometer / light
are later, data-driven additions (the host exposes `gyro_3d`, `magn_3d`, `als`). The
gbinder/HIDL layer already supports them; only `SensorFW.cpp` + `build.json` need extending.

Known risk handled by `takeover`: the in-container stub owns the service name at boot, so after
the daemon is up the stub is stopped and `sensorservice` restarted to rebind to ours.

Companion to [`da_waydroid-apps`](../da_waydroid-apps). Waydroid itself is still not declaratively
enabled in a flake — separate follow-up.

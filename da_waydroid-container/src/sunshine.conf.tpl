# Sunshine config for waydroid-container — rendered from this template by
# entrypoint.sh (@VARS@ substituted from build.json via env). Sunshine captures the
# headless sway output via the wlroots screencopy/dmabuf protocols (capture=wlr) and
# hardware-encodes it with VAAPI on the passed-through Intel render node — the GPU
# half of the Moonlight streaming pipeline.
#
# State (paired Moonlight clients + web credentials) lives on the /var/lib/waydroid
# data VOLUME, so pairing survives container recreation and credentials never touch
# the image or git.
capture = wlr
encoder = vaapi
adapter_name = @RENDER_NODE@
file_state = /var/lib/waydroid/sunshine/sunshine_state.json
credentials_file = /var/lib/waydroid/sunshine/sunshine_state.json
file_apps = /etc/sunshine-apps.json
log_path = /var/log/sunshine.log
sunshine_name = waydroid-container
min_log_level = info

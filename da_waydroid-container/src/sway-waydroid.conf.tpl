# sway config for the waydroid-container headless compositor — rendered from this
# template by entrypoint.sh (@WIDTH@/@HEIGHT@ substituted from build.json via the
# WAYDROID_WIDTH/WAYDROID_HEIGHT env vars). Replaces Debian's default /etc/sway/config,
# which is a DESKTOP config: it starts swaybar (stole 33px of the output and put a
# tray/clock in the Android screen), references a wallpaper file this image doesn't
# ship, and tries to launch Xwayland — none of that belongs in a single-purpose
# Android compositor.
#
# The headless output must be given the real target resolution explicitly — wlroots'
# headless backend otherwise creates a fixed default 1280x720 output (confirmed live:
# `swaymsg -t get_outputs` showed 1280x720 while build.json declared 2304x1536).
output HEADLESS-1 mode --custom @WIDTH@x@HEIGHT@
output HEADLESS-1 bg #000000 solid_color

# The Waydroid UI is the only client — it should be a borderless fullscreen surface,
# not a tiled window with sway decorations.
default_border none
focus_follows_mouse no

# etc-self-heal — repair a dangling /etc/static (left by a FAILED
# nix-on-droid switch whose orphaned etc got GC'd: /etc/{passwd,resolv.conf,
# group} dangle → no SSH/DNS → and you can't switch to fix it because
# activation needs a working /etc). Repairs from the LIVE, GC-rooted
# generation etc. No-op when healthy. Called from bash profileExtra and
# fish interactiveShellInit on every login.
if [ ! -e /etc/static/passwd ]; then
  _ge=$(readlink -f /nix/var/nix/profiles/nix-on-droid/etc 2>/dev/null)
  [ -n "$_ge" ] && [ -e "$_ge/passwd" ] && ln -sfn "$_ge" /etc/static 2>/dev/null || true
fi
exit 0

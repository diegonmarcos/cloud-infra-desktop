# Fish greeting / welcome screen - Termux / nix-on-droid
{ config, pkgs, lib, ... }:

{
  programs.fish.functions.fish_greeting = ''
    # ── Gather all data (local only, no network calls) ──
    set -l _cpu (uname -m 2>/dev/null; or echo "n/a")
    set -l _cores (nproc 2>/dev/null; or echo "?")
    set -l _mt (free -h 2>/dev/null | awk '/Mem:/{print $2}'); test -z "$_mt"; and set _mt "n/a"
    set -l _mu (free -h 2>/dev/null | awk '/Mem:/{print $3}'); test -z "$_mu"; and set _mu "n/a"
    set -l _kern (uname -r 2>/dev/null | string split "-" | head -1; or echo "n/a")
    set -l _host (hostname 2>/dev/null; or echo "termux")
    set -l _up (uptime -p 2>/dev/null | string replace "up " ""); test -z "$_up"; and set _up "n/a"
    set -l _nix ("$HOME/.nix-profile/bin/nix" --version 2>/dev/null | string replace -r ".*\\) " ""); test -z "$_nix"; and set _nix "n/a"
    set -l _hmg "n/a"
    if test -L "$HOME/.local/state/nix/profiles/home-manager"
      set _hmg (readlink "$HOME/.local/state/nix/profiles/home-manager" 2>/dev/null | string replace -r ".*-(\\d+)-link" '$1')
      test -z "$_hmg"; and set _hmg "n/a"
    end
    set -l _wg "down"; set -l _wgip "n/a"
    set -l _wo (ip -4 addr show wg0 2>/dev/null | string match -r "inet (\\S+)/" | tail -1)
    if test -n "$_wo"; set _wg "up"; set _wgip "$_wo"; end
    set -l _lan (ip -4 route get 1 2>/dev/null | string match -r "src (\\S+)" | tail -1)
    test -z "$_lan"; and set _lan "n/a"
    set -l _dhome (df -h ~ 2>/dev/null | awk 'NR==2{print $3"/"$2}'); test -z "$_dhome"; and set _dhome "n/a"
    set -l _dpct (df -h ~ 2>/dev/null | awk 'NR==2{print $5}'); test -z "$_dpct"; and set _dpct "n/a"
    set -l _dnix (df -h /nix 2>/dev/null | awk 'NR==2{print $3"/"$2}'); test -z "$_dnix"; and set _dnix "n/a"
    set -l _gbr (git -C "$HOME" branch --show-current 2>/dev/null; or echo "n/a")
    set -l _grepo (bash -c 'ls -1d ~/git/*/.git 2>/dev/null | wc -l | tr -d " "'); test -z "$_grepo"; and set _grepo "0"
    set -l _gdirty (git -C "$HOME" status --porcelain 2>/dev/null | wc -l | string trim); test -z "$_gdirty"; and set _gdirty "0"

    # ══════════════════ H1: Title Banner ══════════════════
    set_color --bold cyan
    echo "═══════════════════════════════════════════════════════════════════════════════════════════════"
    echo "   Nix-on-Droid Terminal"
    echo "═══════════════════════════════════════════════════════════════════════════════════════════════"
    set_color normal; echo ""

    # ══════════════════ H2: System ══════════════════
    set_color --bold yellow; echo "── System ─────────────────────────────────────────────────────────────────────────────────────"
    set_color normal

    # Row 1: Hardware | OS | Nix
    set_color yellow
    printf "┌─ Hardware ────────────────────┐ ┌─ OS ──────────────────────────┐ ┌─ Nix ─────────────────────────┐\n"
    printf "│"; set_color normal; printf " %-30s" "Arch: $_cpu ($_cores cores)"; set_color yellow; printf "│ │"; set_color normal; printf " %-30s" "Type: Android/Termux"; set_color yellow; printf "│ │"; set_color normal; printf " %-29s" "Nix: $_nix"; set_color yellow; printf "│\n"
    printf "│"; set_color normal; printf " %-30s" "RAM: $_mu / $_mt"; set_color yellow; printf "│ │"; set_color normal; printf " %-30s" "Host: $_host"; set_color yellow; printf "│ │"; set_color normal; printf " %-29s" "HM Generation: $_hmg"; set_color yellow; printf "│\n"
    printf "│"; set_color normal; printf " %-30s" "Kernel: $_kern"; set_color yellow; printf "│ │"; set_color normal; printf " %-30s" "Shell: fish"; set_color yellow; printf "│ │"; set_color normal; printf " %-29s" "HM: git/unix/bb_flakes_termux"; set_color yellow; printf "│\n"
    printf "│"; set_color normal; printf " %-30s" ""; set_color yellow; printf "│ │"; set_color normal; printf " %-30s" "Uptime: $_up"; set_color yellow; printf "│ │"; set_color normal; printf " %-29s" "OS Flake: n/a (Termux)"; set_color yellow; printf "│\n"
    printf "└────────────────────────────────┘ └────────────────────────────────┘ └───────────────────────────────┘\n"
    set_color normal

    # ══════════════════ H2: Network & Data ══════════════════
    set_color --bold cyan; echo "── Network & Data ─────────────────────────────────────────────────────────────────────────────"
    set_color normal

    # Row 2: Network | Storage | Git
    set_color cyan
    printf "┌─ Network ─────────────────────┐ ┌─ Storage ─────────────────────┐ ┌─ Git ─────────────────────────┐\n"
    printf "│"; set_color normal; printf " WG: "
    if test "$_wg" = "up"; set_color green; printf "● up "; else; set_color red; printf "○ dn "; end
    set_color normal; printf "%-24s" "IP: $_wgip"; set_color cyan; printf "│ │"; set_color normal; printf " %-30s" "Home: $_dhome ($_dpct)"; set_color cyan; printf "│ │"; set_color normal; printf " %-29s" "Branch: $_gbr"; set_color cyan; printf "│\n"
    printf "│"; set_color normal; printf " %-30s" "LAN: $_lan"; set_color cyan; printf "│ │"; set_color normal; printf " %-30s" "Nix:  $_dnix"; set_color cyan; printf "│ │"; set_color normal; printf " %-29s" "Repos: $_grepo  Dirty: $_gdirty"; set_color cyan; printf "│\n"
    printf "│"; set_color normal; printf " %-30s" ""; set_color cyan; printf "│ │"; set_color normal; printf " %-30s" ""; set_color cyan; printf "│ │"; set_color normal; printf " %-29s" ""; set_color cyan; printf "│\n"
    printf "│"; set_color normal; printf " %-30s" ""; set_color cyan; printf "│ │"; set_color normal; printf " %-30s" ""; set_color cyan; printf "│ │"; set_color normal; printf " %-29s" ""; set_color cyan; printf "│\n"
    printf "└────────────────────────────────┘ └────────────────────────────────┘ └───────────────────────────────┘\n"
    set_color normal; echo ""

    # ══════════════════ H2: Configuration ══════════════════
    set_color --bold magenta; echo "── Configuration ──────────────────────────────────────────────────────────────────────────────"
    set_color normal
    # H3: Wrappers - Guardrails
    set_color cyan; echo "  Wrappers - Guardrails:"
    set_color normal
    set_color red; echo -n "    BLOCKED "; set_color normal; echo "rm -rf /, mkfs, dd (always denied)"
    set_color yellow; echo -n "    CONFIRM "; set_color normal; echo "npm npx docker nix pip apt pkg (ask before run)"
    set_color blue; echo -n "    WARNING "; set_color normal; echo "bun cargo go (warn on write ops)"
    # H3: Wrappers - Custom
    set_color cyan; echo "  Wrappers - Custom:"
    set_color normal
    set_color green; echo -n "    curl    "; set_color normal; echo "Auto-inject Authelia bearer token for *.diegonmarcos.com"
    set_color green; echo -n "    wget    "; set_color normal; echo "Auto-inject Authelia bearer token for *.diegonmarcos.com"
    # H3: Env Vars
    set_color cyan; echo "  Env Vars:"
    set_color normal
    set_color magenta; echo -n "    LD_PRELOAD       "; set_color normal; echo "mimalloc (memory allocator fix)"
    set_color magenta; echo -n "    TF_PLUGIN_CACHE  "; set_color normal; echo "~/.terraform.d/plugin-cache"
    if test -n "$CLOUDFLARE_API_TOKEN"
      set_color green; echo -n "    CF_API_TOKEN     "; set_color normal; echo "● set"
    else
      set_color red; echo -n "    CF_API_TOKEN     "; set_color normal; echo "○ not set"
    end
    if test -f "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/monitoring-read.json"
      set_color green; echo -n "    AUTHELIA_TOKEN   "; set_color normal; echo "● available"
    else
      set_color red; echo -n "    AUTHELIA_TOKEN   "; set_color normal; echo "○ not found"
    end
    echo ""

    # ══════════════════ H2: Commands ══════════════════
    set_color --bold green; echo "── Commands ───────────────────────────────────────────────────────────────────────────────────"
    set_color normal
    # H3: Tools
    set_color cyan; echo "  Tools:"
    set_color normal
    set_color green; echo -n "    c       "; set_color normal; echo "Launch Claude Code"
    set_color green; echo -n "    claude-malloc "; set_color normal; echo "Launch Claude Code (malloc workaround)"
    set_color green; echo -n "    code    "; set_color normal; echo "VS Code Server (local/lan/stop)"
    # H3: Git
    set_color cyan; echo "  Git:"
    set_color normal
    set_color yellow; echo -n "    gacp    "; set_color normal; echo "git add . && commit && push"
    set_color yellow; echo -n "    gcl     "; set_color normal; echo "git clone <url>"
    # H3: Cloud
    set_color cyan; echo "  Cloud:"
    set_color normal
    set_color red; echo -n "    curl    "; set_color normal; echo "Auto-injects Authelia token for *.diegonmarcos.com"
    set_color red; echo -n "    mesh    "; set_color normal; echo "WireGuard VPN (status, config, peers)"
    # H3: System
    set_color cyan; echo "  System:"
    set_color normal
    set_color magenta; echo -n "    up      "; set_color normal; echo "Rebuild Nix config"
    set_color magenta; echo -n "    conf    "; set_color normal; echo "Edit flake.nix"
    set_color magenta; echo -n "    sync    "; set_color normal; echo "File sync & serve (WebDAV SFTP HTTP+Eruda)"
    set_color magenta; echo -n "    connect "; set_color normal; echo "Unified dashboard (git/mounts/sync/servers)"
    set_color magenta; echo -n "    server  "; set_color normal; echo "Dev server control (dev/stop/status)"
    if test -n "$__httpd_pid"; and kill -0 $__httpd_pid 2>/dev/null
      set_color green; echo -n "    http-dev"; set_color normal; echo -n " ● Web+MD+Eruda "; set_color cyan; echo -n "http://127.0.0.1:$__httpd_port"; set_color normal; echo " (PID: $__httpd_pid)"
    else
      set_color red; echo -n "    http-dev"; set_color normal; echo " ○ Not running"
    end
    # H3: Search
    set_color cyan; echo "  Search (fzf):"
    set_color normal
    set_color blue; echo -n "    Ctrl+T  "; set_color normal; echo "Find file"
    set_color blue; echo -n "    Ctrl+R  "; set_color normal; echo "Search history"
    set_color blue; echo -n "    Alt+C   "; set_color normal; echo "Cd to folder"

    set_color cyan; echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════════════════════"
    set_color normal
  '';
}

# Fish shell configuration — FULLY DATA-DRIVEN.
#
# Every abbreviation, alias and function comes from ONE file:
#   modules/data/fish-commands.json
# and so does the Aliases/Functions section of fish_greeting (via the
# generated __cloud_commands_help function). Adding a command means editing
# that JSON — never this file — and the greeting updates with it, so it can
# no longer advertise commands that don't exist (the 2026-08-08 audit found
# http-dev, nmtui, dlog and dex advertised but never installed).
{ config, pkgs, lib, ... }:

let
  cmds = builtins.fromJSON (builtins.readFile ../../data/fish-commands.json);

  # ── generators ─────────────────────────────────────────────────────
  toAttrs = f: list: builtins.listToAttrs (map f list);

  abbrAttrs  = toAttrs (a: { name = a.name; value = a.cmd; }) cmds.abbrs;
  aliasAttrs = toAttrs (a: { name = a.name; value = a.cmd; }) cmds.aliases;

  # A function is either a file under ./fish/functions/, an inline body, or
  # generated here (__cloud_commands_help).
  realFns = builtins.filter (f: !(f.generated or false)) cmds.functions;
  fnAttrs = toAttrs (f: {
    name  = f.name;
    value = if f ? file then builtins.readFile (./fish/functions + "/${f.file}") else f.body;
  }) realFns;

  # ── greeting help — generated from the SAME data ────────────────────
  # Rendered at build time into a fish function body: zero subprocesses at
  # greeting time (the 2026-08-08 perf pass cut ~46 spawns per shell; this
  # section adds none).
  visible = list: builtins.filter (x: !(x.hidden or false)) list;
  # `·` in the ·abbr suffix is 2 bytes but ONE column, and stringLength counts
  # bytes — measuring it raw left every abbr row a column left of its neighbours.
  dispLen = x: builtins.stringLength (builtins.replaceStrings [ "·" ] [ "x" ] x);
  pad = s:
    let n = 17 - dispLen s;
    in s + lib.concatStrings (lib.genList (_: " ") (if n > 1 then n else 1));

  # Descriptions land inside a double-quoted fish string, so $ and " must be
  # escaped — an unescaped $HOME in a desc was EXPANDED at greeting time
  # ("serve /root over HTTP"), caught by rendering the generated function
  # before shipping it.
  esc = builtins.replaceStrings [ "\\" "\"" "$" ] [ "\\\\" "\\\"" "\\$" ];

  line = color: suffix: item:
    ''set_color ${color}; echo -n "    ${pad (item.name + suffix)}"; set_color normal; echo "${esc (item.desc or "")}"'';

  itemsFor = gid:
       map (line "cyan"   " ·abbr") (builtins.filter (a: (a.group or "other") == gid) (visible cmds.abbrs))
    ++ map (line "yellow" "")       (builtins.filter (a: (a.group or "other") == gid) (visible cmds.aliases))
    ++ map (line "green"  "()")     (builtins.filter (f: (f.group or "other") == gid) (visible cmds.functions));

  groupBlock = g:
    let items = itemsFor g.id;
    in if items == [] then "" else ''
      set_color cyan; echo "  ${g.title}:"
      set_color normal
      ${lib.concatStringsSep "\n      " items}
    '';

  helpBody = ''
    # GENERATED from modules/data/fish-commands.json by fish.nix — do not
    # edit. Legend: name ·abbr = expands on space · name() = function ·
    # bare name = alias.
    set_color --bold yellow
    echo "── Aliases & Functions ────────────────────────────────────────────────────────────────────────"
    set_color normal
    ${lib.concatStringsSep "\n    " (map groupBlock cmds.groups)}
    set_color --dim; echo "    (source: modules/data/fish-commands.json — hhelp alias for the full dump)"; set_color normal
  '';

  # ── env vars — same contract, same generator shape ──────────────────
  # The old greeting hand-listed these names and printed only set/unset, so it
  # drifted from what the flake actually declares and never showed a value.
  # Now: one JSON, rendered at build time, values read LIVE at greeting time.
  envs = builtins.fromJSON (builtins.readFile ../../data/fish-envvars.json);

  padE = s:
    let n = 32 - builtins.stringLength s;
    in s + lib.concatStrings (lib.genList (_: " ") (if n > 1 then n else 1));

  # `set -q NAME` takes the bare name; ''$${v.name} renders a literal `$NAME`
  # for fish's own expansion, so the VALUE is whatever is really exported now.
  # Long values (store paths) are cut to keep the two-column layout intact.
  envLine = v: ''
    set_color yellow; echo -n "    ${padE v.name}"
        if set -q ${v.name}
          ${if (v.secret or false)
            then ''set_color --dim green; echo "set (hidden)"''
            else ''set_color normal; echo (string sub -l 72 -- "''$${v.name}")''}
        else
          set_color --dim red; echo "unset"
        end
        set_color normal'';

  envGroupBlock = g:
    let items = map envLine (builtins.filter (v: (v.group or "other") == g.id) envs.vars);
    in if items == [] then "" else ''
      set_color cyan; echo "  ${g.title}:"
      set_color normal
      ${lib.concatStringsSep "\n      " items}
    '';

  envHelpBody = ''
    # GENERATED from modules/data/fish-envvars.json by fish.nix — do not edit.
    # Names come from that file; values are read live, so `unset` is real.
    set_color --bold yellow
    echo "── Env Vars ───────────────────────────────────────────────────────────────────────────────────"
    set_color normal
    ${lib.concatStringsSep "\n    " (map envGroupBlock envs.groups)}
    set_color --dim; echo "    (source: modules/data/fish-envvars.json — secrets shown as 'set (hidden)')"; set_color normal
  '';
in
{
  programs.fish = {
    enable = true;

    shellAbbrs = abbrAttrs;

    # fish.nix owns ALL fish aliases (from the JSON). flake.nix no longer
    # sets programs.fish.shellAliases — it derives bash/zsh sharedAliases
    # from the same JSON's shared:true entries, so the two sets can never
    # collide or drift.
    shellAliases = aliasAttrs;

    functions = fnAttrs // {
      __cloud_commands_help = helpBody;
      __cloud_envvars_help  = envHelpBody;
    };

    interactiveShellInit = builtins.readFile ./fish/interactiveShellInit.fish;
  };
}

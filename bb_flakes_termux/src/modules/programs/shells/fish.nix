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
  pad = s:
    let n = 17 - builtins.stringLength s;
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

    functions = fnAttrs // { __cloud_commands_help = helpBody; };

    interactiveShellInit = builtins.readFile ./fish/interactiveShellInit.fish;
  };
}

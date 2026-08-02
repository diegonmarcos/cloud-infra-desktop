# my-ai/ — Claude Code + wrappers, claude-superset proxy, Anthropic CLI,
# Google Antigravity, Gemini CLI. Owner module for everything AI-desktop.
# Migrated from modules/ai/ (a Phase-0 scaffold that never got filled).
{ ... }:
{
  imports = [
    ./claude.nix
    ./claude-superset.nix
    ./ant.nix
    ./antigravity.nix
    ./gemini.nix
  ];
}

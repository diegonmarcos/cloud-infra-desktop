# my-ai/ — Claude Code + wrappers, my-ai (Rust, sole hub binary — replaces the
# old claude-superset bash+node tool, now fully ported natively), Anthropic
# CLI, Google Antigravity, Gemini CLI. Owner module for everything AI-desktop.
# Migrated from modules/ai/ (a Phase-0 scaffold that never got filled).
{ ... }:
{
  imports = [
    ./claude.nix
    ./ant.nix
    ./antigravity.nix
    ./gemini.nix
  ];
}

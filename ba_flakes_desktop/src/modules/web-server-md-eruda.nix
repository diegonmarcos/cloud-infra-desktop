# Web server with Markdown rendering + Eruda DevTools
# Provides: http-dev command (start|stop|status|restart)
# Wraps: web-server-md-eruda.mjs (Node.js file server)
{ config, pkgs, lib, ... }:

let
  httpDevScript = pkgs.writeShellScript "http-dev" (builtins.readFile ./scripts/http-dev.sh);
in
{
  # Deploy the .mjs server + libs
  home.file.".local/bin/web-server-md-eruda.mjs".source = ./dotfiles/web-server-md-eruda.mjs;
  home.file.".local/lib/httpd/marked.min.js".source = ./dotfiles/httpd-lib/marked.min.js;
  home.file.".local/lib/httpd/github-markdown-dark.css".source = ./dotfiles/httpd-lib/github-markdown-dark.css;
  home.file.".local/lib/httpd/browse.html".source = ./dotfiles/httpd-lib/browse.html;

  # Deploy the POSIX wrapper as http-dev
  home.file.".local/bin/http-dev" = {
    source = httpDevScript;
    executable = true;
  };

  # Systemd user service — start on login (not per-shell like termux)
  systemd.user.services.http-dev = {
    Unit.Description = "http-dev — Node.js file server (Markdown + Eruda)";
    Service = {
      ExecStart = "${pkgs.nodejs_20}/bin/node %h/.local/bin/web-server-md-eruda.mjs 8000 %h";
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}

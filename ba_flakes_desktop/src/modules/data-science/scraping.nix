# data-science/scraping.nix — Python web scraping libs
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    python312Packages.beautifulsoup4
    python312Packages.scrapy
  ];
}

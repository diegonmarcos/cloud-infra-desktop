#!/usr/bin/env bash
if [ -z "$1" ]; then
  printf "\033[0;31mError: Repository URL required\033[0m\n"
  printf "Usage: gcl <url> [folder]\n"
  printf "Examples:\n"
  printf "  gcl git@github.com:user/repo.git\n"
  printf "  gcl https://github.com/user/repo.git\n"
  printf "  gcl https://github.com/user/repo.git myrepo\n"
  exit 1
fi
printf '\033[0;36m→ Cloning %s...\033[0m\n' "$1"
if [ -n "$2" ]; then
  git clone "$1" "$2" || exit 1
else
  git clone "$1" || exit 1
fi
printf "\033[0;32m✓ Done\033[0m\n"

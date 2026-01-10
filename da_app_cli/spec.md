  ---
  Why this is smart
  ┌───────────────────┬────────┬──────────────────────────────────────────────┐
  │       What        │ Where  │                     Why                      │
  ├───────────────────┼────────┼──────────────────────────────────────────────┤
  │ gcc 13            │ Nix    │ Don't need gcc 11, 12, 13, 14 simultaneously │
  ├───────────────────┼────────┼──────────────────────────────────────────────┤
  │ openssl           │ Nix    │ Security-critical, pin it                    │
  ├───────────────────┼────────┼──────────────────────────────────────────────┤
  │ clang + llvm      │ Nix    │ Huge, stable, one version enough             │
  ├───────────────────┼────────┼──────────────────────────────────────────────┤
  │ Python 3.11       │ Nix    │ Interpreter is stable                        │
  ├───────────────────┼────────┼──────────────────────────────────────────────┤
  │ requests, numpy   │ Poetry │ Changes per project                          │
  ├───────────────────┼────────┼──────────────────────────────────────────────┤
  │ Django 4.2 vs 5.0 │ Poetry │ Project-specific                             │
  └───────────────────┴────────┴──────────────────────────────────────────────┘
  ---
  The split

  NIX handles:                    POETRY handles:
  ─────────────                   ───────────────
  gcc, clang, rustc               numpy, pandas
  openssl, zlib, curl             requests, httpx
  llvm, libffi                    django, flask
  git, make, cmake                pytest, black
  python3.11                      project-specific deps
  poetry (the tool)               fast-moving pypi

# poc_common.sh — shared helpers for the POC scripts. Source it:
#   . "$SCRIPT_DIR/poc_common.sh"
# Not executable on its own.

# find_python: echo a working python3 (>=3.6, stdlib-only is all we need).
# Under sudo, PATH is often reset to a secure_path that excludes
# /usr/local/bin and the repo owner's pyenv, so a bare `python3` may be
# "command not found" even though an interpreter exists. Search the usual
# spots plus the repo owner's home. Override with PYTHON=/path.
# Usage: PYBIN="$(find_python "$REPO_DIR")" || { echo no python; exit 1; }
find_python() {
  repo_dir="${1:-.}"
  for p in "${PYTHON:-}" python3 /usr/local/bin/python3 /usr/bin/python3 /bin/python3 python; do
    [ -n "$p" ] || continue
    if command -v "$p" >/dev/null 2>&1 && \
       "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3,6) else 1)' 2>/dev/null; then
      command -v "$p"; return 0
    fi
  done
  # repo owner's interpreter (pyenv-style / explicit venv), e.g.
  # /home/ddi-auto-user/python/bin/python3 on the POC box
  owner="$(stat -c %U "$repo_dir" 2>/dev/null || true)"
  home="$(getent passwd "$owner" 2>/dev/null | cut -d: -f6)"
  for p in "$home/python/bin/python3" "$home/.pyenv/shims/python3" "$home/venv/bin/python3"; do
    [ -n "$home" ] && [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

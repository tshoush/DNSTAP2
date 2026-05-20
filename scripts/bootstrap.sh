#!/usr/bin/env bash
# DNSTAP2 — interactive bootstrap.
#
# - Detects OS (Ubuntu, RHEL, WSL2, macOS) and prints platform-specific hints.
# - Prompts for the Python executable to use (with a sane default).
# - Validates that it is Python 3.11+ (we need stdlib tomllib).
# - Creates .venv and installs the project.
# - Records the chosen interpreter to .python-path for setup.sh to consume.
#
# Re-runnable: pass --recreate to blow away an existing .venv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

RECREATE=0
for arg in "$@"; do
  case "$arg" in
    --recreate) RECREATE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# OS detection
# ─────────────────────────────────────────────────────────────────────────────
OS_FAMILY="unknown"
OS_PRETTY="unknown"
RHEL_MAJOR=""
IS_WSL=0

if [[ "$(uname -s)" == "Darwin" ]]; then
  OS_FAMILY="macos"
  OS_PRETTY="macOS $(sw_vers -productVersion 2>/dev/null || echo unknown)"
elif [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_PRETTY="${PRETTY_NAME:-${ID:-linux}}"
  case "${ID:-}${ID_LIKE:-}" in
    *rhel*|*centos*|*rocky*|*almalinux*|*fedora*)
      OS_FAMILY="redhat"
      RHEL_MAJOR="$(echo "${VERSION_ID:-}" | cut -d. -f1)"
      ;;
    *debian*|*ubuntu*) OS_FAMILY="debian" ;;
    *) OS_FAMILY="linux" ;;
  esac
fi

# WSL2 detection — the WSL kernel always has "microsoft" or "WSL" in its release.
if [[ -r /proc/sys/kernel/osrelease ]] && \
   grep -qiE "microsoft|wsl" /proc/sys/kernel/osrelease 2>/dev/null; then
  IS_WSL=1
fi

# Systemd availability
HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && \
   [[ -d /run/systemd/system ]]; then
  HAS_SYSTEMD=1
fi

echo "==> DNSTAP2 bootstrap"
echo "  OS         : $OS_PRETTY"
echo "  family     : $OS_FAMILY${RHEL_MAJOR:+ (RHEL major=$RHEL_MAJOR)}"
echo "  WSL2       : $([[ $IS_WSL -eq 1 ]] && echo yes || echo no)"
echo "  systemd    : $([[ $HAS_SYSTEMD -eq 1 ]] && echo yes || echo no)"
echo

# ─────────────────────────────────────────────────────────────────────────────
# Platform-specific notes
# ─────────────────────────────────────────────────────────────────────────────
print_python_install_hints() {
  case "$OS_FAMILY" in
    redhat)
      if [[ "$RHEL_MAJOR" == "7" ]]; then
        cat <<'EOF'
  RHEL/CentOS 7 ships Python 2.7 only. Options for getting Python 3.11+:

    # IUS community repo:
    sudo yum install -y https://repo.ius.io/ius-release-el7.rpm
    sudo yum install -y python311 python311-pip
    # then re-run this bootstrap with /usr/bin/python3.11

    # Or build from source (no network repos):
    sudo yum groupinstall -y "Development Tools"
    sudo yum install -y openssl-devel bzip2-devel libffi-devel zlib-devel
    curl -O https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz
    tar xf Python-3.11.9.tgz && cd Python-3.11.9
    ./configure --enable-optimizations --prefix=/usr/local
    make -j"$(nproc)" && sudo make altinstall
    # binary then lives at /usr/local/bin/python3.11

EOF
      fi
      ;;
    debian)
      if [[ $IS_WSL -eq 1 ]]; then
        cat <<'EOF'
  Under WSL2 (Ubuntu) you typically already have a working python3. If it
  is older than 3.11, add the deadsnakes PPA:

    sudo add-apt-repository ppa:deadsnakes/ppa -y
    sudo apt-get update
    sudo apt-get install -y python3.11 python3.11-venv python3.11-dev

EOF
      else
        cat <<'EOF'
  On Debian/Ubuntu, install Python 3.11:
    sudo apt-get update
    sudo apt-get install -y python3.11 python3.11-venv python3.11-dev
  (or use the deadsnakes PPA if your release doesn't have it).

EOF
      fi
      ;;
    macos)
      cat <<'EOF'
  Install Python 3.11+ via Homebrew:
    brew install python@3.12

EOF
      ;;
  esac
}

print_wsl_note() {
  if [[ $IS_WSL -eq 1 ]]; then
    cat <<'EOF'

  ───── WSL2 networking note ─────────────────────────────────────────────────
  InfoBlox will dial INTO your receiver. From the InfoBlox grid master,
  your WSL VM is NOT directly addressable — only your Windows host is.
  Two ways to make it work:

  (1) Mirrored networking (Windows 11 22H2+):
      Put this in %UserProfile%\.wslconfig and restart WSL:
          [wsl2]
          networkingMode=mirrored
      Then the Windows host IP and your WSL IP are the same; nothing else
      to do. Set receiver.advertised_host in config.toml to the Windows
      host's LAN IP.

  (2) netsh portproxy (any Windows 10/11):
      From an Administrator PowerShell on the Windows host:
          netsh interface portproxy add v4tov4 \
              listenport=6000 listenaddress=0.0.0.0 \
              connectport=6000 connectaddress=$(wsl hostname -I | awk '{print $1}')
          New-NetFirewallRule -DisplayName "dnstap 6000" -Direction Inbound \
              -Protocol TCP -LocalPort 6000 -Action Allow
      Set receiver.advertised_host in config.toml to the Windows host's LAN IP.

  ────────────────────────────────────────────────────────────────────────────

EOF
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Find Python candidates
# ─────────────────────────────────────────────────────────────────────────────
CANDIDATES=(python3.13 python3.12 python3.11 python3 python)
# RHEL 7 IUS installs to /usr/bin/python3.11; SCL to /opt/rh/...; from-source
# defaults to /usr/local/bin/python3.11 via `make altinstall`.
EXTRA_PATHS=(
  /usr/local/bin/python3.13
  /usr/local/bin/python3.12
  /usr/local/bin/python3.11
  /opt/python/3.11/bin/python3.11
  /opt/rh/rh-python311/root/usr/bin/python3.11
)

best=""
best_version=""
for c in "${CANDIDATES[@]}"; do
  if command -v "$c" >/dev/null 2>&1; then
    ver=$("$c" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
    major=${ver%%.*}
    minor=${ver##*.}
    if [[ "$major" -gt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -ge 11 ]]; }; then
      best="$(command -v "$c")"
      best_version="$ver"
      break
    fi
  fi
done

if [[ -z "$best" ]]; then
  for p in "${EXTRA_PATHS[@]}"; do
    if [[ -x "$p" ]]; then
      ver=$("$p" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
      major=${ver%%.*}
      minor=${ver##*.}
      if [[ "$major" -gt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -ge 11 ]]; }; then
        best="$p"
        best_version="$ver"
        break
      fi
    fi
  done
fi

if [[ -z "$best" ]]; then
  echo "  ! no Python 3.11+ found on PATH or in standard locations."
  echo
  print_python_install_hints
  echo "  Once installed, re-run this script. You can also pass an explicit"
  echo "  path at the prompt below."
  echo
fi

# ─────────────────────────────────────────────────────────────────────────────
# Prompt for Python executable (with default)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -n "$best" ]]; then
  echo "  Found Python $best_version at: $best"
  printf "  Python executable to use [%s]: " "$best"
else
  printf "  Path to Python 3.11+ executable: "
fi

if [[ -t 0 ]]; then
  read -r CHOICE
else
  # Non-interactive (e.g. piped). Use detected default or fail.
  CHOICE=""
  echo
fi

PYTHON_EXE="${CHOICE:-$best}"
if [[ -z "$PYTHON_EXE" ]]; then
  echo "no Python executable selected — aborting." >&2
  exit 1
fi

# Validate the chosen interpreter
if ! [[ -x "$PYTHON_EXE" ]]; then
  # Maybe the user gave us a name on PATH rather than a path.
  if command -v "$PYTHON_EXE" >/dev/null 2>&1; then
    PYTHON_EXE="$(command -v "$PYTHON_EXE")"
  else
    echo "  ! $PYTHON_EXE is not executable" >&2
    exit 1
  fi
fi

CHECK=$("$PYTHON_EXE" - <<'PY'
import sys
v = sys.version_info
print(f"{v.major}.{v.minor}.{v.micro}")
sys.exit(0 if (v.major, v.minor) >= (3, 11) else 7)
PY
) || {
  echo "  ! $PYTHON_EXE reports version $CHECK — need 3.11+." >&2
  exit 1
}
echo "  using Python $CHECK at $PYTHON_EXE"

# Make sure venv module is present.
if ! "$PYTHON_EXE" -c 'import venv' 2>/dev/null; then
  echo "  ! the 'venv' module is not available with $PYTHON_EXE."
  echo "    On Debian/Ubuntu/WSL try: sudo apt-get install -y ${PYTHON_EXE##*/}-venv"
  echo "    On RHEL/CentOS make sure you installed the corresponding *-devel/-libs package."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Create the venv
# ─────────────────────────────────────────────────────────────────────────────
if [[ -d .venv && $RECREATE -eq 1 ]]; then
  echo "  removing existing .venv (--recreate)"
  rm -rf .venv
fi

if [[ ! -d .venv ]]; then
  echo "  creating .venv with $PYTHON_EXE"
  "$PYTHON_EXE" -m venv .venv
else
  echo "  .venv already exists (use --recreate to rebuild)"
fi

# Persist the chosen interpreter so setup.sh and other tools can find it.
echo "$PYTHON_EXE" > .python-path

# Upgrade pip and install the project in editable mode.
echo "  installing project (this may take a minute)"
.venv/bin/python -m pip install --quiet --upgrade pip setuptools wheel
.venv/bin/python -m pip install --quiet -e ".[dev]"

# ─────────────────────────────────────────────────────────────────────────────
# Smoke test
# ─────────────────────────────────────────────────────────────────────────────
echo "  running smoke tests"
.venv/bin/python -m pytest -q

echo
print_wsl_note
echo "==> bootstrap complete"
echo "  next: cp config.example.toml config.toml && \$EDITOR config.toml"
echo "        export INFOBLOX_PASSWORD=infoblox"
echo "        ./scripts/setup.sh"

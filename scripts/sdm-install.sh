#!/bin/bash
set -euo pipefail

# Determine script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Where you want the installed runtime files to live
INSTALL_DIR="/opt/pymc_repeater"
CONFIG_DIR="/etc/pymc_repeater"
LOG_DIR="/var/log/pymc_repeater"
DATA_DIR="/var/lib/pymc_repeater"

SERVICE_USER="repeater"
SERVICE_NAME="pymc-repeater"

echo "[pymc] starting install..."
echo "[pymc] Source directory determined as: $SRC_DIR"

if [ "${EUID:-0}" -ne 0 ]; then
  echo "[pymc] ERROR: must run as root"
  exit 1
fi

# Validate source checkout (not INSTALL_DIR)
if [ ! -f "$SRC_DIR/pyproject.toml" ]; then
  echo "[pymc] ERROR: $SRC_DIR/pyproject.toml not found (is the repo cloned to $SRC_DIR?)"
  exit 1
fi

echo "[pymc] creating service user..."
if ! id "$SERVICE_USER" &>/dev/null; then
  useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi

echo "[pymc] adding user to hardware groups (best-effort)..."
usermod -a -G gpio,i2c,spi "$SERVICE_USER" 2>/dev/null || true
usermod -a -G dialout "$SERVICE_USER" 2>/dev/null || true

echo "[pymc] creating directories..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR"

echo "[pymc] installing system dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends \
  git ca-certificates \
  libffi-dev jq python3-pip python3-rrdtool wget swig build-essential python3-dev

python3 -m pip install --break-system-packages -q setuptools_scm || true

echo "[pymc] installing mikefarah/yq v4 (only if missing/wrong)..."
if ! command -v yq >/dev/null 2>&1 || ! (yq --version 2>&1 | grep -q "mikefarah/yq"); then
  YQ_VERSION="v4.40.5"
  case "$(uname -m)" in
    x86_64)  YQ_BINARY="yq_linux_amd64" ;;
    armv7*)  YQ_BINARY="yq_linux_arm" ;;
    aarch64) YQ_BINARY="yq_linux_arm64" ;;
    *)       YQ_BINARY="yq_linux_arm64" ;;
  esac
  wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}"
  chmod +x /usr/local/bin/yq
fi

echo "[pymc] generating _version.py (best-effort)..."
if [ -d "$SRC_DIR/.git" ]; then
  (cd "$SRC_DIR" && git fetch --tags 2>/dev/null) || true
  (cd "$SRC_DIR" && python3 -c "from setuptools_scm import get_version; get_version(write_to='repeater/_version.py')" ) || true
fi

echo "[pymc] installing runtime files into $INSTALL_DIR..."
# Clean old runtime payload (optional but keeps things sane)
rm -rf "$INSTALL_DIR/repeater" 2>/dev/null || true

# Copy the project runtime bits
cp -r "$SRC_DIR/repeater" "$INSTALL_DIR/"
cp "$SRC_DIR/pyproject.toml" "$INSTALL_DIR/"
[ -f "$SRC_DIR/README.md" ] && cp "$SRC_DIR/README.md" "$INSTALL_DIR/" || true
[ -f "$SRC_DIR/manage.sh" ] && cp "$SRC_DIR/manage.sh" "$INSTALL_DIR/" || true

# Service + defaults
if [ -f "$SRC_DIR/pymc-repeater.service" ]; then
  cp "$SRC_DIR/pymc-repeater.service" "$INSTALL_DIR/"
  cp "$SRC_DIR/pymc-repeater.service" /etc/systemd/system/
fi

if [ -f "$SRC_DIR/config.yaml.example" ]; then
  cp "$SRC_DIR/config.yaml.example" "$CONFIG_DIR/config.yaml.example"
  if [ ! -f "$CONFIG_DIR/config.yaml" ]; then
    cp "$CONFIG_DIR/config.yaml.example" "$CONFIG_DIR/config.yaml"
  fi
fi

[ -f "$SRC_DIR/radio-settings.json" ] && cp "$SRC_DIR/radio-settings.json" "$DATA_DIR/" || true
[ -f "$SRC_DIR/radio-presets.json"  ] && cp "$SRC_DIR/radio-presets.json"  "$DATA_DIR/" || true

echo "[pymc] configuring polkit rule..."
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/10-pymc-repeater.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "pymc-repeater.service" &&
        subject.user == "repeater") {
        return polkit.Result.YES;
    }
});
EOF
chmod 0644 /etc/polkit-1/rules.d/10-pymc-repeater.rules

echo "[pymc] setting permissions..."
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR"
chmod 750 "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR" || true
chmod 755 "$DATA_DIR" || true
mkdir -p "$DATA_DIR/.config/pymc_repeater"
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR/.config"

echo "[pymc] installing python package (from source at $SRC_DIR)..."
export PIP_ROOT_USER_ACTION=ignore
export PIP_ONLY_BINARY=pycryptodome,cffi,PyNaCl,psutil
export SETUPTOOLS_SCM_PRETEND_VERSION="0.0.0+sdm"

cd "$SRC_DIR"
python3 -m pip install --break-system-packages --no-cache-dir .

# Verify pymc_core installation
if python3 -c "import pymc_core; print(f'pymc_core version: {pymc_core.__version__}')" 2>/dev/null; then
    echo "[pymc] ✓ pymc_core installed successfully"
else
    echo "[pymc] ⚠ pymc_core import failed - check installation logs"
fi

echo "[pymc] enabling service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"

# Starting during image build can fail; don’t hard fail
systemctl start "$SERVICE_NAME" 2>/dev/null || true

echo "[pymc] install complete."

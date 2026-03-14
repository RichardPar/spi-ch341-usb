#!/usr/bin/env bash
# sign-module.sh - sign spi-ch341-usb.ko for Secure Boot (MOK) and import the signing key
#
# Usage:
#   sudo ./sign-module.sh [--module <path>] [--key-dir <dir>] [--reboot]
#
# This script:
# 1) Generates a signing keypair (if missing)
# 2) Signs the built module using the kernel sign-file helper
# 3) Imports the public certificate into the machine owner key (MOK)
#
# After running, reboot and follow the MOK manager prompt to enroll the key.

set -euo pipefail

MODULE_PATH="${MODULE_PATH:-$(pwd)/spi-ch341-usb.ko}"
KEY_DIR="${KEY_DIR:-/root/module-signing}"
REBOOT=false

print_usage() {
  cat <<EOF
Usage: sudo $0 [options]

Options:
  --module <path>   Path to the built .ko module (default: $MODULE_PATH)
  --key-dir <dir>   Directory to store the signing key and cert (default: $KEY_DIR)
  --reboot          Reboot automatically after importing the cert
  -h, --help        Show this help message
EOF
}

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)."
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module)
      MODULE_PATH="$2"; shift 2;;
    --key-dir)
      KEY_DIR="$2"; shift 2;;
    --reboot)
      REBOOT=true; shift;;
    -h|--help)
      print_usage; exit 0;;
    *)
      echo "Unknown option: $1" >&2; print_usage; exit 1;;
  esac
done

if [[ ! -f "$MODULE_PATH" ]]; then
  echo "ERROR: Module not found: $MODULE_PATH"
  exit 1
fi

mkdir -p "$KEY_DIR"

KEY_PRIV="$KEY_DIR/MOK.key"
KEY_CERT="$KEY_DIR/MOK.crt"
KEY_CERT_DER="$KEY_DIR/MOK.der"

if [[ ! -f "$KEY_PRIV" || ! -f "$KEY_CERT" ]]; then
  echo "Generating module signing keypair in $KEY_DIR..."
  openssl req -new -x509 -newkey rsa:4096 -nodes \
    -keyout "$KEY_PRIV" -out "$KEY_CERT" -days 3650 \
    -subj "/CN=spi-ch341-usb module signing/"
  chmod 600 "$KEY_PRIV"
fi

# Convert to DER for mokutil (mokutil expects DER format)
if [[ ! -f "$KEY_CERT_DER" || "$KEY_CERT" -nt "$KEY_CERT_DER" ]]; then
  openssl x509 -in "$KEY_CERT" -outform der -out "$KEY_CERT_DER"
fi

KBUILD_DIR="/usr/src/linux-headers-$(uname -r)"
SIGN_FILE="$KBUILD_DIR/scripts/sign-file"

if [[ ! -x "$SIGN_FILE" ]]; then
  echo "ERROR: kernel sign-file helper not found at $SIGN_FILE" >&2
  exit 1
fi

echo "Signing module: $MODULE_PATH"
"$SIGN_FILE" sha256 "$KEY_PRIV" "$KEY_CERT" "$MODULE_PATH"

echo "Importing public cert into MOK (this will require a reboot to finish)"

mokutil --import "$KEY_CERT_DER"

if [[ "$REBOOT" == true ]]; then
  echo "Rebooting now..."
  systemctl reboot
else
  echo "Done. Reboot and enroll the key via the MOK manager screen."
  echo "You can check Secure Boot status with: mokutil --sb-state"
fi

#!/bin/bash
# Creates a local code signing certificate, "Ghostty Dock Local", in the login
# keychain, so builds signed with it keep macOS permissions (Full Disk Access,
# folders, notifications, Automation) across rebuilds. An ad-hoc signature
# changes with every build and macOS forgets what it granted. Run once per Mac;
# scripts/sign-id.sh picks the certificate up. Signs on this Mac only: sharing
# a build still needs a Developer ID.
set -euo pipefail

NAME="Ghostty Dock Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

function usage() {
    echo "usage: $(basename "$0") [-h]   create the '$NAME' code signing certificate once"
    exit 0
}

function main() {
    case "${1:-}" in -h | --help) usage ;; esac
    if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "== '$NAME' is already in the login keychain"
        return 0
    fi
    local pass
    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp:-}"' EXIT
    pass=$(openssl rand -hex 16)
    cat >"$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    # The keychain reads only the older PKCS#12 ciphers.
    openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
        -passout "pass:$pass" -out "$tmp/id.p12" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
    security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
    echo "== created '$NAME' in the login keychain"
}

main "$@"

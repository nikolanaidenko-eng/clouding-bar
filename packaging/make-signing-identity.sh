#!/bin/bash
# Creates a self-signed code signing certificate in its own keychain, so
# every build is signed by the same identity and macOS keeps Clouding Bar's
# Accessibility permission across rebuilds. The keychain has an empty
# password, stays off your keychain search list, and holds nothing else.
# Run once: make signing-identity
set -euo pipefail
KEYCHAIN="$1"
NAME="$2"

if [ -f "$KEYCHAIN" ]; then
  echo "Signing keychain already exists: $KEYCHAIN"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# -legacy: macOS's importer can't read OpenSSL 3's default PKCS#12 ciphers.
openssl pkcs12 -export -legacy -name "$NAME" -passout pass:claudebar \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12"

mkdir -p "$(dirname "$KEYCHAIN")"
# create-keychain may add itself to the search list; put the list back.
SEARCH_LIST=$(security list-keychains -d user | tr -d '"')
security create-keychain -p "" "$KEYCHAIN"
security list-keychains -d user -s $SEARCH_LIST
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "" "$KEYCHAIN"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P claudebar -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null
echo "Created signing identity \"$NAME\" in $KEYCHAIN"

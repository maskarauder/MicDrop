#!/usr/bin/env bash
# Install from a reviewed rendezvous CI artifact. Existing route secrets survive.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail 'Run this installer with sudo.'
bundle_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
binary='' config='' hostname='' cert='' key='' listen='0.0.0.0:8443'
while (($#)); do
    (($# >= 2)) || fail 'Every option requires a value.'
    case "$1" in
        --binary) binary=$2 ;;
        --config) config=$2 ;;
        --hostname) hostname=$2 ;;
        --caddy-cert) cert=$2 ;;
        --caddy-key) key=$2 ;;
        --listen) listen=$2 ;;
        *) fail 'Options: --binary --config --hostname --caddy-cert --caddy-key [--listen]' ;;
    esac
    shift 2
done
[[ -f $binary && -f $config && -n $hostname && -n $cert && -n $key ]] || fail 'Provide binary, existing config, hostname and both Caddy certificate paths.'
[[ $hostname =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && $listen =~ ^[][A-Za-z0-9.:-]+$ ]] || fail 'Invalid hostname or listen address.'
for path in "$cert" "$key"; do
    [[ $path == /var/lib/caddy/* && $path =~ ^[A-Za-z0-9_./-]+$ && $path != */../* ]] || fail 'Use plain absolute certificate paths below /var/lib/caddy.'
done
[[ $cert != "$key" && ${cert%/*} == "${key%/*}" ]] || fail 'Use distinct cert/key files in the same directory.'
for command in python3 setfacl runuser useradd systemctl install cmp; do
    command -v "$command" >/dev/null || fail "Install the missing prerequisite: $command"
done
systemctl is-active --quiet micdrop-rendezvous.service && fail 'Stop the existing rendezvous service while idle before installing an update.'
help_text=$("$binary" serve --help 2>&1 || true)
[[ $help_text == *tls-reload-interval* ]] || fail 'Use the new rendezvous build with certificate reload support.'
"$binary" check --config "$config" --tls-cert "$cert" --tls-key "$key" --tls-name "$hostname"
if [[ -e /etc/micdrop-rendezvous/config.json ]]; then
    cmp -s -- "$config" /etc/micdrop-rendezvous/config.json || fail 'Installed configuration differs. Keep the existing route secrets; review changes manually.'
fi
if ! id micdrop >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /var/lib/micdrop-rendezvous --shell /usr/sbin/nologin micdrop
fi
[[ $(id -u micdrop) != 0 && $(id -gn micdrop) == micdrop ]] || fail 'Expected an unprivileged micdrop account with primary group micdrop.'
[[ $(getent passwd micdrop | cut -d: -f7) == /usr/sbin/nologin ]] || fail 'The micdrop account must use /usr/sbin/nologin.'
install -d -o root -g micdrop -m 0750 /etc/micdrop-rendezvous
if [[ ! -e /etc/micdrop-rendezvous/config.json ]]; then
    install -o root -g micdrop -m 0640 -- "$config" /etc/micdrop-rendezvous/config.json
fi
install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 -- "$bundle_dir/caddy-access.py" /usr/local/libexec/micdrop-caddy-access.py
/usr/bin/python3 /usr/local/libexec/micdrop-caddy-access.py --cert "$cert" --key "$key"
binary_tmp=$(mktemp /usr/local/bin/.micdrop-rendezvous.XXXXXX)
trap 'rm -f -- "$binary_tmp"' EXIT
install -o root -g root -m 0755 -- "$binary" "$binary_tmp"
mv -f -- "$binary_tmp" /usr/local/bin/micdrop-rendezvous
runuser -u micdrop -- /usr/local/bin/micdrop-rendezvous check --config /etc/micdrop-rendezvous/config.json \
    --tls-cert "$cert" --tls-key "$key" --tls-name "$hostname"
printf 'MICDROP_LISTEN=%s\nMICDROP_HOSTNAME=%s\nCADDY_CERT=%s\nCADDY_KEY=%s\n' \
    "$listen" "$hostname" "$cert" "$key" > /etc/micdrop-rendezvous/service.conf
chmod 0600 /etc/micdrop-rendezvous/service.conf
install -o root -g root -m 0644 -- "$bundle_dir/micdrop-rendezvous.service" \
    "$bundle_dir/micdrop-caddy-access.service" "$bundle_dir/micdrop-caddy-access.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now micdrop-caddy-access.timer micdrop-rendezvous.service
printf '%s\n' 'Installed. Check systemctl status micdrop-rendezvous and make the external HTTPS test in SERVICE_DEPLOYMENT.md.'

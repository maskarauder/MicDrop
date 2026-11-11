# Rendezvous service deployment

This operator guide covers the Linux rendezvous service and Caddy certificate
renewal. Use the current `rendezvous-linux-x64` developer artifact, including its
`systemd/` directory, or build from the matching source. See [remote access](REMOTE_ACCESS.md)
for first-time private configuration and TURN setup. Existing installations must
reuse their configuration and route tokens.

Caddy remains responsible for ACME issuance and renewal. The `micdrop` account
only reads the selected certificate/key. It cannot write them, list Caddy's
private directories, or read other protected certificate files. Do not add it
to a broadly privileged group or recursively change Caddy ownership/permissions.

## Install on Ubuntu

Stop the old foreground rendezvous with Ctrl+C while no session is using it.
Keep Caddy and coturn running. For an existing systemd installation, first use
`sudo systemctl stop micdrop-rendezvous` while idle. The installer refuses to
replace a running service or overwrite a differing private configuration.

Extract the new artifact and copy **the whole directory**, including `systemd/`,
to the VPS. In that directory, mark the downloaded binary executable:

```sh
chmod +x micdrop-rendezvous
sudo apt-get update
sudo apt-get install --yes acl python3
```

Use your existing private config and Caddy certificate paths. Do **not** run
`init` again. This example uses the ordinary packaged Caddy storage layout;
replace `signal.example.com` in all three arguments and adjust `--config` to
the file currently used by the working foreground server:

```sh
sudo bash systemd/install.sh \
  --binary ./micdrop-rendezvous \
  --config ./rendezvous-private/config.json \
  --hostname signal.example.com \
  --caddy-cert /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/signal.example.com/signal.example.com.crt \
  --caddy-key /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/signal.example.com/signal.example.com.key
```

The default listener is `0.0.0.0:8443`; use `--listen` only if your deployment
differs. Keep the already working TCP firewall rule and HTTPS endpoint. This
service still serves TLS itself; a plaintext reverse-proxy upstream is not
supported. No firewall rules, Caddy configuration, or coturn settings are changed
by the installer.

The installer:

1. Validates the existing config and matching, currently valid certificate/key,
   including hostname coverage. It requires a reload-capable binary.
2. Creates the unprivileged `micdrop` account with a nologin shell, installs the
   executable under `/usr/local/bin`, and copies the existing config to
   `/etc/micdrop-rendezvous/config.json` (root:micdrop, 0640; directory 0750).
3. Grants directory traversal and file read ACLs only for the specified Caddy
   files, then validates access as `micdrop`. Source paths must be under
   `/var/lib/caddy`; symlinks and multiply linked/nonregular files are rejected.
4. Installs and enables `micdrop-rendezvous.service` and
   `micdrop-caddy-access.timer`. The server starts at boot and restarts on failure.
   Its filesystem is read-only; it has no Linux capabilities.

The root-owned `/etc/micdrop-rendezvous/service.conf` contains the hostname,
listener and certificate paths, not route credentials. Root may edit it when a
hostname, ACME issuer directory or listener changes. Rerun the access helper and
restart rendezvous while idle after changing those paths. The root timer's only
job is maintaining these two read ACLs; it does not read or copy key contents.

## Verify before closing SSH

```sh
sudo systemctl status micdrop-rendezvous --no-pager
sudo systemctl list-timers micdrop-caddy-access.timer --all --no-pager
sudo journalctl -u micdrop-rendezvous -u micdrop-caddy-access --since '10 minutes ago' --no-pager
```

From Windows, use the real hostname:

```powershell
curl.exe --http1.1 -i --max-time 10 https://signal.example.com:8443/v1/ice
```

**HTTP 401 Unauthorized is expected**, and establishes DNS/TCP/TLS reachability
and token admission. Then use the saved remote invitation for one playback or
duplex connection and Stop/reconnect. No fresh pairing/export should be needed.
Close SSH and reconnect to confirm the service is still active; no reboot is
needed just to test the installation. Verify boot persistence on the next
convenient VPS reboot.

## Renewal and certificate reload

Caddy can replace certificate files with mode 0600. A one-time ACL or default
directory ACL does not guarantee effective access to the replacement. The
one-minute timer reapplies access to the exact current files; descriptor-based
updates avoid following a changed symlink. Directory traversal does not grant
permission to list or write their contents. Ownership remains with Caddy.

Rendezvous independently checks its certificate files once a minute by default
(`--tls-reload-interval`, 1s–24h). It loads the pair together, checks matching
keys, validity dates and optional `--tls-name`, and atomically switches the
certificate used for **new TLS handshakes**. Existing HTTPS/WSS connections stay
open. Normal renewal should be picked up within roughly two minutes, plus timer
scheduling. Check for `TLS certificate reloaded. Existing connections remain open.`
in the journal after renewal.

A temporary missing file, read denial, half-written/mismatched pair, wrong
hostname or invalid date retains the previously loaded certificate and logs one
failure until reads recover. The service keeps retrying. It will not serve an
expired cached certificate to a new connection. Monitor renewal and the service
journal; automatic retries cannot repair a Caddy issuance failure or a changed
source path. Clients still perform ordinary certificate-chain/hostname checks;
local `check` does not prove client trust or ACME renewal.

To refresh access and preflight the files immediately, without a restart:

```sh
sudo systemctl start micdrop-caddy-access.service
sudo -u micdrop /usr/local/bin/micdrop-rendezvous check \
  --config /etc/micdrop-rendezvous/config.json \
  --tls-cert /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/signal.example.com/signal.example.com.crt \
  --tls-key /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/signal.example.com/signal.example.com.key \
  --tls-name signal.example.com
```

Wait for the next certificate poll to change the live certificate. Do not force
an ACME renewal or replace the production certificate with a self-signed test
just to exercise this. Automated tests rotate local test certificates, verify
the new serial on fresh TLS connections, retain an active encrypted connection,
reject invalid renewals, and exercise real Linux ACL replacement/access rules.
Verify installation and actual certificate renewal on each deployment; automated
fixtures do not establish the state of your VPS.

Configuration/token changes still require `sudo systemctl restart
micdrop-rendezvous` and interrupt active tunnels. A binary update also requires
a restart: stop while idle and rerun the installer with the installed config as
`--config /etc/micdrop-rendezvous/config.json`. Retain a private backup of this
configuration; recreating it changes the remote credentials.

This timer covers **rendezvous**, not coturn. A UDP-only TURN listener
does not use a TLS certificate. When TURN TLS is enabled, provision its service
account and certificate-refresh behavior separately; see
[remote access](REMOTE_ACCESS.md#coturn-credential-and-deployment-boundary).

## Roll back

Stop/disable `micdrop-rendezvous` and `micdrop-caddy-access.timer`, then run the
previous binary from SSH with the original private config and protected
certificate copies. Keep Caddy and coturn running. The old binary requires a
restart after certificate changes. Existing route secrets were preserved by the
installer. To remove the named ACLs, use `setfacl -x u:micdrop` on the exact two
files and their Caddy ancestor directories before removing the `micdrop` user;
do not recursively reset ACLs or file ownership.

## References

- [Caddy service/storage layout](https://caddyserver.com/docs/running)
- [Caddy certificate file storage](https://github.com/caddyserver/certmagic/blob/master/filestorage.go)
- [Linux ACL creation/mask rules](https://man7.org/linux/man-pages/man5/acl.5.html)
- [systemd timers](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
- [Go TLS certificate selection](https://pkg.go.dev/crypto/tls#Config)

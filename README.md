# FCOS-Infrastruktur

Dieses Repository beschreibt einen minimalen Bare-Metal-Stack aus Fedora CoreOS,
BlueBuild, Butane/Ignition, Btrfs und GHCR. Die erste Maschine ist `luebeck`.
GitHub Actions baut nur das OCI-Systemimage; Ignition und Installer-ISO entstehen
ausschliesslich lokal.

## Voraussetzungen

- Podman und GNU Make
- fuer den optionalen Smoke-Test: QEMU, OpenSSH und der private SSH-Schluessel

Butane, `ignition-validate`, `coreos-installer`, BlueBuild und Cosign laufen in
Containern. Vor einem lokalen Build muessen zwei nicht versionierte Dateien
angelegt werden:

```text
local/luebeck/authorized_keys
local/luebeck/image-ref
```

`authorized_keys` enthaelt genau einen gueltigen OpenSSH-Public-Key.
`image-ref` enthaelt genau eine OCI-Referenz ohne Transport-Praefix, etwa
`ghcr.io/acme/luebeck:stable`.

## Lokaler Build

`MACHINE` ist bei allen maschinenbezogenen Targets Pflicht. Es gibt keinen Default.

```bash
make ignition MACHINE=luebeck
make iso MACHINE=luebeck
make installer MACHINE=luebeck  # beides
```

Die Ergebnisse sind `build/luebeck/luebeck.ign` und
`build/luebeck/luebeck-installer.iso`. Das ISO installiert ohne Rueckfrage und
ueberschreibt `/dev/nvme0n1` vollstaendig. Es nutzt das komplette FCOS-Live-ISO
offline und uebernimmt die standardmaessige DHCP-Konfiguration.

Nach dem ersten Start rebased `image-rebase.service` zunaechst auf die
unverifizierte OCI-Referenz. Nach dem Neustart ist die Signing-Policy des Images
verfuegbar; die Unit wechselt auf `ostree-image-signed:docker://...`, setzt nach
erfolgreichem Rebase einen Marker und startet nochmals neu.

### Deklarative Service-Benutzer und Konfiguration

`luebeck` definiert `headscale` mit UID/GID 1010, `caddy` mit UID/GID 1011 und
`adguard` mit UID/GID 1012 ueber `systemd-sysusers`. Alle Homes sind normale
Verzeichnisse unter
`/var/home`; sie sind keine eigenen Subvolumes und enthalten nur reproduzierbaren
Rootless-Podman-Zustand. `systemd-tmpfiles` erzeugt die Homes, aktiviert Linger
und legt stattdessen die persistenten Btrfs-Subvolumes
`/var/lib/service-data/headscale`, `/var/lib/service-data/caddy` und
`/var/lib/service-data/adguard` an.
Eine Boot-Unit verifiziert die Subvolumes, bevor die User-systemd-Manager starten.

Die Rootless-Quadlets liegen direkt in den von Podman vorgesehenen
UID-spezifischen Verzeichnissen `/etc/containers/systemd/users/1010` und
`/etc/containers/systemd/users/1011` und `/etc/containers/systemd/users/1012`.
Es werden keine Dateien in die Homes
kopiert. Die Konfiguration der Container liegt getrennt von eventuell nativ
installierten Diensten unter `/etc/container-services/headscale` und
`/etc/container-services/caddy`. Fuer Headscale liefert das Image vorerst nur
`config.yaml.example`; ohne die produktive `config.yaml` verhindert
`ConditionPathExists` dessen Containerstart. Caddys produktive Konfiguration ist
dagegen deklarativ als `Caddyfile` im Image enthalten.

Dateien unter `/etc` sind OSTree-Konfigurationsdefaults. Lokale Aenderungen
bleiben bei einem Image-Update erhalten und werden sichtbar mit:

```bash
sudo ostree admin config-diff
sudo diff -u /usr/etc/container-services/caddy/Caddyfile \
  /etc/container-services/caddy/Caddyfile
```

Der lokale YubiKey-Key wird nicht ins OCI-Image aufgenommen. Ignition installiert
ihn fuer `core` und zusaetzlich unter `/etc/ssh/authorized_keys/headscale` sowie
`/etc/ssh/authorized_keys/adguard`. `headscale` und `adguard` erlauben
ausschliesslich Public-Key-SSH ohne Forwarding; `caddy` hat `nologin` und wird
von `core` via `sudo` beziehungsweise `runuser` administriert.

Headscale v0.29.3 bindet HTTP lokal an Port 10000 und Metrics/Debug lokal an
10001. Seine persistenten Daten werden aus
`/var/lib/service-data/headscale` nach `/var/lib/headscale` gemountet.
Ein bewusster lokaler Test-Override wird analog aktiviert:

```bash
sudo cp /etc/container-services/headscale/config.yaml.example \
  /etc/container-services/headscale/config.yaml
sudoedit /etc/container-services/headscale/config.yaml
sudo -u headscale env XDG_RUNTIME_DIR=/run/user/1010 \
  /usr/libexec/service-containers start
```

### Rootless AdGuard Home

AdGuard Home v0.107.79 verwendet UID/GID 1012 und damit den lokalen Portblock
ab 12000. DNS wird im Container auf Port 53 angenommen und auf dem Host als
TCP/UDP 12000 veroeffentlicht. Die Public-Zone von firewalld leitet TCP und UDP
53 direkt auf 12000 um. Die Weboberflaeche liegt nur lokal auf
`127.0.0.1:12001` und wird von
Caddy als `adguard-admin.home.mairhoefer.xyz` ausschliesslich fuer die im
`internal_clients`-Snippet definierten Netze bereitgestellt.

Die aus dem Rescue-Verzeichnis uebernommene Default-Konfiguration liegt im Git
unter `/etc/container-services/adguard/AdGuardHome.yaml` und wird schreibbar nach
`/opt/adguardhome/conf` gemountet. AdGuard darf sie daher lokal aktualisieren;
Abweichungen vom Image-Default zeigt `ostree admin config-diff`. Das
Work-Verzeichnis bleibt im gesicherten Subvolume unter
`/var/lib/service-data/adguard/data`. Die rund 1,1 GiB geretteten Laufzeitdaten
werden von dem Rechner, auf dem `/home/work/rescue` liegt, so uebertragen:

```bash
rsync -a --no-owner --no-group --chmod=D750,F600 \
  /home/work/rescue/root/root/adguard/data/ \
  adguard@luebeck:/var/lib/service-data/adguard/data/
ssh adguard@luebeck \
  'XDG_RUNTIME_DIR=/run/user/1012 /usr/libexec/service-containers start'
```

Query-Logs, Sessions, Filterkopien und Statistiken werden nicht ins Image
aufgenommen.

### Rootless Caddy als Reverse Proxy

Caddys Zertifikate, Schluessel und Laufzeitkonfiguration liegen unter
`/var/lib/service-data/caddy/{data,config}` und werden nach `/data` und
`/config` gemountet. Der deklarative Caddyfile kommt read-only aus
`/etc/container-services/caddy` und erscheint im Container weiterhin unter
`/etc/caddy`.

Der Caddy-Container verwendet Host-Networking und kann dadurch Headscale unter
`127.0.0.1:10000` erreichen, ohne dessen Port extern zu oeffnen. Die Portbloecke
folgen den Service-UIDs: Headscale mit UID 1010 verwendet 10000/10001, Caddy mit
UID 1011 verwendet 11000 fuer HTTP und 11001 fuer HTTPS sowie HTTP/3.
Die Public-Zone von firewalld leitet TCP 80 nach 11000 sowie TCP und UDP 443
nach 11001 um. Es wird weder `net.ipv4.ip_unprivileged_port_start` veraendert
noch einem Benutzer `CAP_NET_BIND_SERVICE` gegeben.

Das gemeinsame Image installiert und aktiviert firewalld. Fuer `luebeck`
definiert `/etc/firewalld/zones/public.xml` die lokalen Portweiterleitungen fuer
Caddy und AdGuard deklarativ. Die Regeln enthalten jeweils nur `port`,
`protocol` und `to-port`; eine Weiterleitungsadresse und separates IP-Forwarding
sind nicht erforderlich.

Das produktive Haupt-Caddyfile enthaelt die globalen Optionen und importiert
`services/*.caddyfile`. Die Synology-Proxies aus der vorherigen Installation
liegen separat in `services/synology.caddyfile`; weitere Dienste koennen dadurch
ohne wachsende Hauptdatei ergaenzt werden. Das wiederverwendbare Snippet
`internal_clients` definiert zentral die erlaubten Tailscale- und LAN-Netze und
wird innerhalb geschuetzter Site-Bloecke importiert. Beide Dateien werden direkt
mit dem Image ausgerollt. Fuer einen bewusst lokalen Override koennen sie auf dem
Rechner angepasst werden:

```bash
sudoedit /etc/container-services/caddy/Caddyfile
sudoedit /etc/container-services/caddy/services/synology.caddyfile
sudo -u caddy env XDG_RUNTIME_DIR=/run/user/1011 \
  /usr/libexec/service-containers start
```

Die A-/AAAA-Eintraege muessen auf den Server zeigen; TCP 80/443 und fuer HTTP/3
auch UDP 443 muessen erreichbar sein.

Alle Rootless-Container eines Benutzers haengen an dessen `containers.target`.
Das gemeinsame `/usr/libexec/service-containers start|stop` steuert deshalb ohne
Servicenamen immer den gesamten Container-Stack des aufrufenden Benutzers.
Backups werden als root mit `/usr/libexec/service-backup headscale`, `caddy`
oder `adguard` gestartet. Der Orchestrator stoppt das Target des
jeweiligen Benutzers, snapshotet nur sein Daten-Subvolume und startet es sofort
wieder. Der read-only Snapshot wird an den Borg-Platzhalter uebergeben und
anschliessend geloescht. Servicespezifische Backup-Hooks gibt es nicht. Home,
Container-Images, Quadlets und `/etc`-Konfiguration werden nicht mitgesichert;
ZIP- oder TAR-Dateien werden nicht erzeugt.

## Validierung und Smoke-Test

```bash
make check
make smoke MACHINE=luebeck SSH_KEY=/pfad/zum/privaten_key
```

`make check` benoetigt keine lokalen Secrets. Es transpiliert beide Butane-Stufen
im Strict-Modus mit Testdaten, validiert die finale Ignition-Datei, expandiert die
BlueBuild-Recipe und prueft Schutzregeln sowie erwartete Fehlerfaelle. Der
Smoke-Test baut bei Bedarf das Installer-ISO, startet es mit einer emulierten
NVMe-Platte und prueft nach den Reboots Hostname, DHCP/SSH, Btrfs und den
signierten rpm-ostree-Origin.

## Image-Signing und CI

Ein Schluesselpaar wird interaktiv erzeugt:

```bash
make signing-key
```

`cosign.pub` wird committed. `cosign.key` bleibt ignoriert; sein kompletter Inhalt
wird manuell als GitHub-Repository-Secret `SIGNING_SECRET` hinterlegt. Die Action
publiziert aus der Recipe-Matrix nur `ghcr.io/<repository-owner>/luebeck:stable`.
Das GHCR-Paket muss nach dem ersten Lauf einmalig auf oeffentlich gestellt werden.

## Weitere Maschinen

Fuer `<name>` werden `recipes/<name>.yml`, `ignition/<name>.bu` und
`installer/<name>.yaml` ergaenzt, danach der Name in `MACHINES` im `Makefile`, in
der CI-Matrix und (mit Architektur/Geraet) in `scripts/machine-config.sh`.
Gemeinsame Image-Dateien liegen in `files/system/`, maschinenspezifische unter
`files/<name>/`. Die gemeinsame Butane-Konfiguration verwendet dabei jeweils
`local/<name>/authorized_keys`. Secrets und private Konfiguration gehoeren unter
`local/<name>/`.

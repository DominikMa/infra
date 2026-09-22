# FCOS-Infrastruktur

Dieses Repository beschreibt einen minimalen Bare-Metal-Stack aus Fedora CoreOS,
BlueBuild, Butane/Ignition, Btrfs und GHCR. Die erste Maschine ist `luebeck`.
GitHub Actions baut nur das OCI-Systemimage; Ignition und Installer-ISO entstehen
ausschliesslich lokal.

## Voraussetzungen

- Podman und GNU Make
- fuer `make image` und `make publish`: die BlueBuild-CLI
- fuer den optionalen Smoke-Test: QEMU, OVMF/UEFI-Firmware, OpenSSH und der
  private SSH-Schluessel

Butane, `ignition-validate` und `coreos-installer` laufen in gepinnten
Containern; `make check` verwendet auch BlueBuild auf diese Weise. Die lokalen
Image-Targets rufen dagegen die installierte BlueBuild-CLI mit Podman als
Build-Treiber auf. Vor einem lokalen Build muessen zwei nicht versionierte
Dateien angelegt werden:

```text
local/luebeck/authorized_keys
local/luebeck/image-ref
```

`authorized_keys` enthaelt einen oder mehrere gueltige OpenSSH-Public-Keys,
jeweils einen pro Zeile. Leerzeilen und Kommentarzeilen sind erlaubt.
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

Das OCI-Systemimage kann unabhaengig von Ignition und Installer-ISO lokal gebaut
werden:

```bash
make image MACHINE=luebeck
```

Zum signierten Build mit anschliessendem Push wird das Ziel aus
`local/luebeck/image-ref` gelesen. Ohne `GHCR_TOKEN` fragt das Target den Token
verdeckt interaktiv ab:

```bash
make publish MACHINE=luebeck
```

Fuer einen nicht-interaktiven Lauf werden Registry-Token und optional der
Benutzername nur ueber die Prozessumgebung uebergeben:

```bash
GHCR_TOKEN='...' GHCR_USERNAME='DominikMa' make publish MACHINE=luebeck
```

Der Token benoetigt Schreibrecht fuer GitHub Packages. Ein Git-/GitHub-SSH-Key
kann nur Git-Operationen authentifizieren und ist kein gueltiger GHCR-Login.
Standardmaessig signiert das Target mit `cosign.key`; ein anderer Pfad kann ueber
`COSIGN_PRIVATE_KEY_FILE` gesetzt werden. Weder Ignition noch ISO werden dabei
veroeffentlicht.

Nach dem ersten Start rebased `image-rebase.service` zunaechst auf die
unverifizierte OCI-Referenz. Nach dem Neustart ist die Signing-Policy des Images
verfuegbar; die Unit wechselt auf `ostree-image-signed:docker://...`, setzt nach
erfolgreichem Rebase einen Marker und startet nochmals neu. Beide bewussten
Rebase-Operationen umgehen dabei den von Zincati gesetzten Update-Treiber; bei
einem transienten Fehler, etwa noch nicht verfuegbarem DNS, versucht systemd den
Schritt nach 30 Sekunden erneut.

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
Ignition installiert die festen, nicht ueberlappenden SubUID-/SubGID-Bereiche
bereits vor dem ersten Boot nach `/etc/subuid` und `/etc/subgid`.

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

Die maschinenspezifischen Konfigurationsverzeichnisse gehoeren bereits im Image
dem jeweiligen Service-Benutzer. Dadurch kann Rootless Podman sie fuer die
weiterhin aktive SELinux-Label-Trennung mit `:Z` kennzeichnen; eine nachtraegliche
Eigentumsaenderung durch `systemd-tmpfiles` ist nicht erforderlich.

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

AdGuard Home v0.107.79 verwendet UID/GID 1012 und ein eigenes Container-Netz.
DNS wird per TCP und UDP als `0.0.0.0:53` und `[::]:53` auf allen IPv4- und
IPv6-Schnittstellen des Hosts veroeffentlicht; damit ist der Dienst ueber
externe und interne Adressen sowie localhost erreichbar. Die Weboberflaeche wird nur als
`127.0.0.1:12001` auf dem Host veroeffentlicht und von
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

### Transparente Netzwerk-Bridge

Die beiden I226-V-Adapter an PCI `02:00.0` und `03:00.0` heissen auf `luebeck`
`enp2s0` und `enp3s0`. Beide sind reine Ports der persistenten Linux-Bridge
`br0`. Nur die Bridge traegt die bisherige statische Host-Konfiguration:
`192.168.7.10/24` sowie die beiden globalen IPv6-Adressen
`2a02:8108:142b:ed00:5516:4aac:9e0a:3c00/64` und
`2a02:8108:142b:ed00:3053:ee4e:e36d:61d8/64`. Auch DNS und die bisherigen
IPv4-/IPv6-Gateways bleiben unveraendert. STP ist deaktiviert. Die Maschine
routet und maskiert den durchgeleiteten Verkehr nicht. NetworkManager erzeugt
fuer die beiden Ports keine zusaetzlichen Default-Profile.

Die Bridge verwendet fest die MAC-Adresse `A8:B8:E0:05:92:E5` von `enp2s0`.
Sie funktioniert auch mit nur einem angeschlossenen Port: Ist der Router an
`enp2s0` angeschlossen und `enp3s0` noch ohne Carrier, bleiben `br0` und die
Host-Adressen ueber `enp2s0` erreichbar. NetworkManager aktiviert beide
Bridge-Port-Profile automatisch; ein Port ohne Link blockiert den anderen
nicht.

Das bisherige Keyfile `luebeck-lan.nmconnection` bleibt absichtlich am selben
Pfad, beschreibt nun aber `br0`. So ersetzt ein Image-Update das bisherige
statische Profil, statt es als konkurrierendes Profil fuer `enp3s0` zu
behalten. SSH, Caddy und AdGuard koennen dadurch weiterhin dieselbe primaere
IPv6-Adresse verwenden.

Vor einer manuellen Umstellung zeigen diese Befehle die Zuordnung nochmals an:

```bash
nmcli device status
ip -br link show enp2s0 enp3s0
readlink -f /sys/bus/pci/devices/0000:02:00.0/net/enp2s0
readlink -f /sys/bus/pci/devices/0000:03:00.0/net/enp3s0
```

Die entsprechenden `nmcli`-Befehle fuer eine manuelle Konfiguration sind
unten dokumentiert. Die Aktivierung sollte an einer lokalen Konsole erfolgen,
da dabei die bestehende SSH-Verbindung kurzzeitig wegfaellt.

```bash
sudo nmcli connection add type bridge ifname br0 con-name luebeck-bridge \
  bridge.stp no \
  bridge.mac-address A8:B8:E0:05:92:E5 \
  connection.autoconnect-ports 1 \
  ipv4.method manual ipv4.addresses 192.168.7.10/24 \
  ipv4.gateway 192.168.7.1 ipv4.dns 192.168.7.1 \
  ipv6.method manual \
  ipv6.addresses 2a02:8108:142b:ed00:5516:4aac:9e0a:3c00/64,2a02:8108:142b:ed00:3053:ee4e:e36d:61d8/64 \
  ipv6.gateway fe80::cece:1eff:fea9:5445 ipv6.ip6-privacy 0
sudo nmcli connection add type ethernet ifname enp2s0 \
  con-name luebeck-bridge-enp2s0 master br0 slave-type bridge
sudo nmcli connection add type ethernet ifname enp3s0 \
  con-name luebeck-bridge-enp3s0 master br0 slave-type bridge

# Alte oder automatisch erzeugte Profile fuer enp2s0/enp3s0 zuerst mit
# `nmcli connection show` identifizieren und dann explizit entfernen, z. B.:
sudo nmcli connection delete luebeck-lan

sudo nmcli connection up luebeck-bridge
sudo nmcli connection up luebeck-bridge-enp2s0
sudo nmcli connection up luebeck-bridge-enp3s0
```

Nach der Aktivierung beziehungsweise nach einem Neustart:

```bash
nmcli device status
nmcli connection show
ip addr show br0
ip addr show enp2s0
ip addr show enp3s0
bridge link
bridge fdb show br br0
```

`enp2s0` und `enp3s0` duerfen dabei keine eigenen IP-Adressen haben. Neben der
Host-Erreichbarkeit muessen DHCP, Router- und Internet-Erreichbarkeit von einem
Client hinter dem Switch getestet werden.

### Rootless Caddy als Reverse Proxy

Caddys Zertifikate, Schluessel und Laufzeitkonfiguration liegen unter
`/var/lib/service-data/caddy/{data,config}` und werden nach `/data` und
`/config` gemountet. Der deklarative Caddyfile kommt read-only aus
`/etc/container-services/caddy` und erscheint im Container weiterhin unter
`/etc/caddy`.

Der Caddy-Container verwendet Host-Networking und kann dadurch Headscale unter
`127.0.0.1:10000` erreichen, ohne dessen Port extern zu oeffnen. Caddy bindet
HTTP direkt an Port 80 sowie HTTPS und HTTP/3 direkt an Port 443, jeweils an
allen IPv4-Adressen und ausschliesslich an der primaeren globalen IPv6-Adresse.

`net.ipv4.ip_unprivileged_port_start = 22` erlaubt den rootless Containern die
direkte Belegung dieser Ports. firewalld bleibt aktiviert und gibt DNS, HTTP,
HTTPS sowie HTTP/3 fuer IPv4 und IPv6 frei; Portweiterleitungen sind nicht
mehr erforderlich.

Das produktive Haupt-Caddyfile enthaelt die globalen Optionen und importiert
`services/*.caddyfile`. Die Synology-Proxies aus der vorherigen Installation
liegen separat in `services/synology.caddyfile`; weitere Dienste koennen dadurch
ohne wachsende Hauptdatei ergaenzt werden. Das wiederverwendbare Snippet
`internal_clients` definiert zentral die erlaubten IPv4- und IPv6-Netze von
Tailscale und dem LAN und wird innerhalb geschuetzter Site-Bloecke importiert.
Beide Dateien werden direkt
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
Die systemweiten User-Manager starten erst nach `network-online.target`. Schlaegt
ein Containerstart dennoch transient fehl, etwa wegen noch nicht verfuegbarem
DNS, wartet die generierte Unit 30 Sekunden vor dem naechsten Versuch.
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
Smoke-Test baut bei Bedarf das Installer-ISO und installiert es in einer ersten
QEMU-Phase mit emulierter NVMe-Platte. Danach startet er dieselbe Platte unter
OVMF/UEFI ohne eingelegtes ISO und prueft nach den Reboots Hostname, DHCP/SSH,
Btrfs und den signierten rpm-ostree-Origin. Die Installationsausgabe liegt in
`build/luebeck/smoke/installer-serial.log`, die Ausgabe des installierten Systems
in `build/luebeck/smoke/serial.log`. Abweichende Firmwarepfade koennen mit
`OVMF_CODE` und `OVMF_VARS` gesetzt werden.

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

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
Build-Treiber auf. Vor einem lokalen Installer-Build muessen vier nicht versionierte
Dateien angelegt werden:

```text
local/luebeck/authorized_keys
local/luebeck/image-ref
local/luebeck/host_key/ssh_host_ed25519_key
local/luebeck/host_key/ssh_host_ed25519_key.pub
```

`authorized_keys` enthaelt einen oder mehrere gueltige OpenSSH-Public-Keys,
jeweils einen pro Zeile. Leerzeilen und Kommentarzeilen sind erlaubt.
`image-ref` enthaelt genau eine OCI-Referenz ohne Transport-Praefix, etwa
`ghcr.io/acme/luebeck:stable`.

Das Ed25519-Host-Key-Paar gibt `luebeck` ueber Neuinstallationen hinweg dieselbe
SSH-Identitaet. Um den Schluessel des laufenden Systems zu uebernehmen, werden
die beiden Dateien sicher nach `local/luebeck/host_key/` kopiert und der private
Schluessel auf Modus `0600` gesetzt. Alternativ erzeugt
`make host-key MACHINE=luebeck` einmalig ein neues Paar; vorhandene Dateien
werden dabei nie ueberschrieben. Der Fingerprint laesst sich mit
`ssh-keygen -lf local/luebeck/host_key/ssh_host_ed25519_key.pub` pruefen. Das Paar muss
zusammen mit den sonstigen lokalen Installationsdaten sicher gesichert werden.
Der private Key wird nur in die lokal erzeugte Ignition-Konfiguration und das
Installer-ISO eingebettet, nicht in Git oder das veroeffentlichte OCI-Image.
Die Dateien unter `build/luebeck/` werden deshalb lokal mit restriktiven Rechten
erzeugt; `.ign` und Installer-ISO muessen wie private Schluessel behandelt werden.

## Lokaler Build

`MACHINE` ist bei allen maschinenbezogenen Targets Pflicht. Es gibt keinen Default.

```bash
make ignition MACHINE=luebeck
make iso MACHINE=luebeck
make installer MACHINE=luebeck  # beides
```

Die Ergebnisse sind `build/luebeck/luebeck.ign` und
`build/luebeck/luebeck-installer.iso`. Das ISO installiert ohne Rueckfrage nach
`/dev/nvme0n1`. Die FCOS-Root-Partition wird bei jeder Installation neu
geschrieben und als 128-GiB-Btrfs-Dateisystem angelegt. Eine vorhandene
GPT-Partition mit dem Partitionslabel `service-data` wird dagegen durch
`coreos-installer` erhalten. Beim ersten Start auf einem leeren Datentraeger
legt Ignition diese Partition im gesamten verbleibenden Platz an, formatiert
sie einmalig als Btrfs und mountet sie unter `/var/lib/service-data`. Das ISO
nutzt das komplette FCOS-Live-ISO offline und uebernimmt die standardmaessige
DHCP-Konfiguration.

Beim Wechsel einer bestehenden Installation auf dieses Layout koennen die
bisherigen Service-Daten nicht automatisch erhalten werden: Sie liegen noch
innerhalb der alten Root-Partition, die den gesamten Datentraeger belegt. Vor
der ersten Neuinstallation mit dem neuen Layout muss `/var/lib/service-data`
daher gesichert und danach auf die neue Datenpartition zurueckgespielt werden.
Ab der darauffolgenden Neuinstallation bleibt die Partition durch
`save-partlabel: service-data` erhalten. Das schuetzt vor Neuformatierung,
ersetzt aber kein separates Backup.

Die Partitionsnummern folgen dem FCOS-x86_64-Disk-Image: 1 ist BIOS-Boot, 2 die
EFI-Systempartition, 3 `/boot` und 4 die Root-Partition. Die eigene
`service-data`-Partition ist deshalb Nummer 5. `wipe_table: false` gilt fuer
Ignition: Nicht beschriebene Partitionen werden nicht pauschal geloescht, die
explizit beschriebenen Partitionen werden aber auf die vorgegebenen Merkmale
geprueft. Root darf mit `resize: true` auf 128 GiB wachsen. Eine unvereinbare
Datenpartition wird nicht stillschweigend geloescht; Ignition bricht ab. Bereits
davor schreibt
`coreos-installer` das FCOS-Image mit den Partitionen 1 bis 4 neu und stellt die
ueber `save-partlabel` und zusaetzlich `save-partindex` gesicherte
Datenpartition wieder her. Label und Nummer bilden damit zwei unabhaengige
Schutzkriterien; das korrekte Label bleibt fuer den spaeteren Mount erforderlich.
Die Groesse von Partition 5 ist bewusst nicht fest vorgegeben: Bei der ersten
Installation belegt sie den groessten verbleibenden freien Bereich; bei einer
Neuinstallation akzeptiert Ignition die durch den Installer erhaltene reale
Groesse. Dadurch fuehren kleine GPT-Ausrichtungsunterschiede nicht zu einem
Fehler.

`with_mount_unit: true` erzeugt bei jeder Neuinstallation die aktivierte Unit
`var-lib-service\\x2ddata.mount` unter `/etc/systemd/system`. Sie mountet das
Btrfs-Dateisystem vor `local-fs.target`. Die Unit ist kein Bestandteil des
BlueBuild-OCI-Images, bleibt aber als lokaler `/etc`-Zustand bei einem
rpm-ostree-Rebase erhalten. Bei einer erneuten Installation erzeugt Ignition
sie wieder aus der eingebetteten Konfiguration.

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

Danach uebernimmt `image-update.timer` die Aktualisierung des eigenen
OCI-Systemimages; Zincati ist im abgeleiteten Image maskiert, weil dessen
Cincinnati-Graph den eigenen GHCR-Digest nicht kennt. Der Timer prueft taeglich
um 04:00 Uhr Europe/Berlin mit bis zu 30 Minuten zufaelliger Verzoegerung den
bereits konfigurierten, signierten `luebeck:stable`-Origin. Ein neuer Digest wird
transaktional als neues Deployment bereitgestellt und anschliessend durch einen
Neustart aktiviert. Gibt es keine Aenderung, beendet sich der Dienst mit dem von
systemd als erfolgreich behandelten Status 77 und startet nicht neu. Verpasste
Pruefungen werden nach dem naechsten Boot nachgeholt.

Der GitHub-Workflow prueft taeglich um 00:17 UTC den amd64-Manifest-Digest des
aktuellen `quay.io/fedora/fedora-coreos:stable` gegen BlueBuilds im bereits
publizierten `luebeck:stable` hinterlegtes Basis-Digest-Label. Nur bei einem
geaenderten FCOS-Basisimage oder einem fehlenden Zielimage wird der geplante
BlueBuild ausgefuehrt. Pushes, Pull Requests und manuelle Workflow-Aufrufe bauen
weiterhin immer.

### Deklarative Service-Benutzer und Konfiguration

`luebeck` definiert ueber `systemd-sysusers` je Dienst einen eigenen Benutzer:

| Benutzer      | UID/GID | Container                               | Host-Ports             |
|---------------|---------|-----------------------------------------|------------------------|
| `headscale`   | 1010    | Headscale                               | `127.0.0.1:10000/10001`|
| `caddy`       | 1011    | Caddy                                   | 80, 443                |
| `adguard`     | 1012    | AdGuard Home                            | 53, `127.0.0.1:12001`  |
| `vaultwarden` | 1013    | Vaultwarden                             | `127.0.0.1:13001`      |
| `smarthome`   | 1014    | Home Assistant, Zigbee2MQTT, Mosquitto  | `127.0.0.1:14001/14002`|
| `mealie`      | 1015    | Mealie                                  | `127.0.0.1:15001`      |
| `onedev`      | 1016    | OneDev                                  | 2222, `127.0.0.1:16001`|

Alle Homes sind normale Verzeichnisse unter
`/var/home`; sie sind keine eigenen Subvolumes und enthalten nur reproduzierbaren
Rootless-Podman-Zustand. `systemd-tmpfiles` erzeugt die Homes, aktiviert Linger
und legt stattdessen auf dem separat gemounteten Daten-Dateisystem je Benutzer
das persistente Btrfs-Subvolume `/var/lib/service-data/<benutzer>` an.
Eine Boot-Unit verifiziert die Subvolumes, bevor die User-systemd-Manager starten.
Ignition installiert die festen, nicht ueberlappenden SubUID-/SubGID-Bereiche
bereits vor dem ersten Boot nach `/etc/subuid` und `/etc/subgid`. Einmalige
Schritte fuer bereits installierte Systeme und die Uebernahme der geretteten
Daten stehen in [MIGRATE.md](MIGRATE.md).

Die Rootless-Quadlets liegen direkt in den von Podman vorgesehenen
UID-spezifischen Verzeichnissen `/etc/containers/systemd/users/<uid>`.
Es werden keine Dateien in die Homes
kopiert. Die Konfiguration der Container liegt getrennt von eventuell nativ
installierten Diensten unter `/etc/container-services/<benutzer>`. Headscales
`config.yaml`, Caddys `Caddyfile`, AdGuards `AdGuardHome.yaml` und Mosquittos
`mosquitto.conf` sind deklarativ im Image enthalten. Geheimnisse wie
`vaultwarden.env` und `mosquitto.passwd` liegen nur lokal auf dem Rechner; das
Image liefert jeweils eine `.example`-Datei, und `ConditionPathExists`
verhindert den Containerstart, solange die echte Datei fehlt.

Dateien unter `/etc` sind OSTree-Konfigurationsdefaults. Lokale Aenderungen
bleiben bei einem Image-Update erhalten und werden sichtbar mit:

```bash
sudo ostree admin config-diff
sudo diff -u /usr/etc/container-services/caddy/Caddyfile \
  /etc/container-services/caddy/Caddyfile
```

Die maschinenspezifischen Konfigurationsverzeichnisse gehoeren bereits im Image
dem jeweiligen Service-Benutzer. Da der OSTree-Drei-Wege-Merge unter `/etc`
lokale Verzeichnismetadaten erhalten kann, stellt `service-data.service` diese
Eigentuemer als root vor dem Start der User-systemd-Manager nochmals rekursiv
sicher. Dafuer wird bewusst nicht `systemd-tmpfiles` verwendet, dessen Schutz
vor unsicheren Pfaduebergaengen bei nicht root-gehoerenden Verzeichnissen
greifen kann. Dadurch kann Rootless Podman die Verzeichnisse fuer die weiterhin
aktive SELinux-Label-Trennung mit `:Z` kennzeichnen.

Fehlgeschlagene Containerstarts werden fruehestens nach 30 Sekunden wiederholt.
Nach fuenf Startversuchen innerhalb von zehn Minuten greift zusaetzlich das
systemd-Startlimit; ein dauerhaft defekter Container wird dadurch nicht
unbegrenzt neu erzeugt.

Der lokale YubiKey-Key wird nicht ins OCI-Image aufgenommen. Ignition installiert
ihn fuer `core` und zusaetzlich unter `/etc/ssh/authorized_keys/<benutzer>` fuer
`headscale`, `adguard`, `vaultwarden`, `smarthome`, `mealie` und `onedev`. Das
Verzeichnis hat Modus `0755`, weil sshd die Datei mit den Rechten des
Zielbenutzers liest; jede Schluesseldatei ist `0600` und gehoert ihrem Benutzer.
Diese Benutzer erlauben
ausschliesslich Public-Key-SSH ohne Forwarding; `caddy` hat `nologin` und wird
von `core` via `sudo` beziehungsweise `runuser` administriert.

### Automatische Container-Updates

Schnelle Sicherheitsupdates haben Vorrang vor Stabilitaet. Alle Anwendungen
ausser Caddy und AdGuard laufen deshalb mit einem `latest`- beziehungsweise
`stable`-Tag und `AutoUpdate=registry`. Der fuer alle Benutzer-Manager
aktivierte `podman-auto-update.timer` prueft taeglich mit bis zu 15 Minuten
zufaelliger Verzoegerung auf neue Images, zieht sie und startet die betroffenen
Container neu. Startet eine Unit danach nicht, rollt Podman auf das vorherige
Image zurueck; fachliche Fehler nach erfolgreichem Start erkennt es nicht.
Caddy und AdGuard tragen kein `AutoUpdate`-Label und bleiben gepinnt. Status und
letzte Laeufe, hier am Beispiel Vaultwarden:

```bash
ssh vaultwarden@luebeck \
  'podman auto-update --dry-run; systemctl --user list-timers podman-auto-update.timer'
```

### Rootless Headscale

Headscale bindet HTTP lokal an Port 10000 und Metrics/Debug lokal an
10001. Caddy stellt es unter `headscale.mairhoefer.xyz` und
`headscale.home.mairhoefer.xyz` bereit. Die `config.yaml` basiert auf dem
offiziellen Beispiel von v0.29.3 mit den Werten der vorherigen Installation:
`server_url` bleibt unveraendert `http://headscale.mairhoefer.xyz:443`, damit
registrierte Clients nicht neu angemeldet werden muessen. Datenbank und
Noise-Schluessel liegen im Subvolume `/var/lib/service-data/headscale`, das nach
`/var/lib/headscale` gemountet wird. Die `extra_records` der MagicDNS-Konfiguration
zeigen auf `100.64.0.6`, die Tailnet-Adresse von `luebeck`.

### Tailscale und Exit-Node

`luebeck` ist mit dem Paket `tailscale` aus dem offiziellen Repository selbst
Mitglied des Tailnets, als `100.64.0.6` beziehungsweise `fd7a:115c:a1e0::6`,
und bietet sich als Exit-Node an. `tailscaled` meldet sich ueber
`https://headscale.mairhoefer.xyz` am lokal laufenden Headscale an. Die
Knotenidentitaet liegt nicht unter `/var/lib/tailscale`, sondern im root-eigenen
Subvolume `/var/lib/service-data/tailscale`, damit sie wie die Service-Daten eine
Neuinstallation uebersteht und `luebeck` seine Adresse behaelt. MagicDNS wird
auf dem Host nicht verwendet (`--accept-dns=false`), damit dessen
Namensaufloesung nicht vom Tailnet abhaengt.

`tailscale0` liegt in der eigenen firewalld-Zone `tailscale`, die SSH, DNS,
HTTP(S), HTTP/3 und OneDev-SSH erlaubt; damit greift auch Caddys
`internal_clients`-Snippet fuer `100.64.0.0/24`. Die Policy
`tailscale-exit-node` leitet nur Verkehr aus dieser Zone in die Zone `public`
weiter und maskiert ihn; dafuer ist IP-Forwarding fuer IPv4 und IPv6 aktiviert.
Die oeffentliche Zone selbst leitet weiterhin nichts weiter. UDP 41641 ist fuer
direkte WireGuard-Verbindungen geoeffnet.

### Rootless AdGuard Home

AdGuard Home v0.107.79 verwendet UID/GID 1012 und ein eigenes Container-Netz.
DNS wird per TCP und UDP ohne eingeschraenkte Host-IP auf Port 53 und damit auf
allen IPv4- und IPv6-Schnittstellen des Hosts veroeffentlicht; damit ist der
Dienst ueber externe und interne Adressen sowie localhost erreichbar. Der
lokale Stub-Listener von `systemd-resolved` ist dafuer deaktiviert. Der Dienst
selbst bleibt fuer NetworkManagers DNS-Verwaltung aktiv; `/etc/resolv.conf`
verweist auf seine Uplink-Datei, sodass die Namensaufloesung des Hosts nicht vom
spaeter startenden AdGuard-Container abhaengt. Die Weboberflaeche wird nur als
`127.0.0.1:12001` auf dem Host veroeffentlicht und von
Caddy als `adguard-admin.home.mairhoefer.xyz` ausschliesslich fuer die im
`internal_clients`-Snippet definierten Netze bereitgestellt.

Die aus dem Rescue-Verzeichnis uebernommene Default-Konfiguration liegt im Git
unter `/etc/container-services/adguard/AdGuardHome.yaml` und wird schreibbar nach
`/opt/adguardhome/conf` gemountet. AdGuard darf sie daher lokal aktualisieren;
Abweichungen vom Image-Default zeigt `ostree admin config-diff`. Das
Work-Verzeichnis bleibt im gesicherten Subvolume unter
`/var/lib/service-data/adguard/data`. Query-Logs, Sessions, Filterkopien und
Statistiken werden nicht ins Image aufgenommen.

### Rootless Vaultwarden

Vaultwarden verwendet ein eigenes Container-Netz. Die
Weboberflaeche und die API werden nur als `127.0.0.1:13001` auf dem Host
veroeffentlicht und von Caddy unter `warden.mairhoefer.xyz` und
`warden.home.mairhoefer.xyz` bereitgestellt. Die Client-IP fuer Logs und
Rate-Limits liest Vaultwarden per `IP_HEADER=X-Forwarded-For` aus dem Header,
den Caddy ohne `trusted_proxies` stets selbst mit der echten Gegenstelle setzt.
WebSocket-Benachrichtigungen laufen seit Vaultwarden 1.29 ueber
denselben Port. Das Subvolume `/var/lib/service-data/vaultwarden` wird direkt
nach `/data` gemountet und enthaelt SQLite-Datenbank, RSA-Schluessel,
Attachments, Sends und Icon-Cache.

Die nicht geheime Konfiguration steht als `Environment=` im Quadlet:
`DOMAIN`, `SIGNUPS_ALLOWED=false` und die SMTP-Parameter mit STARTTLS auf Port
587. Geheimnisse liegen ausschliesslich in der lokalen Datei
`/etc/container-services/vaultwarden/vaultwarden.env`. Die Admin-Oberflaeche
bleibt ohne `ADMIN_TOKEN` deaktiviert. Eine per Admin-Oberflaeche erzeugte
`/data/config.json` wuerde die Umgebungsvariablen ueberschreiben.

### Rootless Smarthome

Home Assistant, Zigbee2MQTT und Mosquitto laufen gemeinsam als `smarthome` im
Container-Netz `smarthome` und erreichen sich dort ueber ihre Containernamen.
Das Netz ist fest auf `10.89.0.0/24` gesetzt, weil Home Assistant diesem Bereich
in seiner `configuration.yaml` als `trusted_proxies` vertraut: Verbindungen von
Caddy erreichen den Container ueber das Gateway dieses Netzes. Home Assistant
(`127.0.0.1:14001`) und die Zigbee2MQTT-Oberflaeche (`127.0.0.1:14002`) stellt
Caddy als `homeassistant.home.mairhoefer.xyz` und
`zigbee2mqtt.home.mairhoefer.xyz` ausschliesslich fuer `internal_clients` bereit.
MQTT wird nicht auf dem Host veroeffentlicht.

Die Daten von Home Assistant und Zigbee2MQTT liegen unter
`/var/lib/service-data/smarthome/{homeassistant,zigbee2mqtt}`; beide schreiben
ihre YAML-Konfiguration selbst und bringen ihre Geheimnisse (`secrets.yaml`,
Netzwerkschluessel, MQTT-Passwort) dort mit. Mosquitto ist zustandslos; seine
`mosquitto.conf` kommt read-only aus `/etc/container-services/smarthome/mosquitto`,
die Passwortdatei `mosquitto.passwd` liegt nur lokal daneben. Weil Mosquitto
2.1 vor dem Lesen der Passwortdatei sonst auf einen eigenen Benutzer wechselt,
setzt die Konfiguration `user root`; im Rootless-Container ist das der
unprivilegierte Host-Benutzer `smarthome`.

Der ConBee-III-Stick wird per `AddDevice` als `/dev/ttyUSB0` durchgereicht. Die
Udev-Regel `70-conbee.rules` uebergibt ihn anhand seiner Seriennummer an
`smarthome`. SELinux verbietet `container_t` den Zugriff auf `usbtty_device_t`,
deshalb laeuft nur dieser Container mit `SecurityLabelDisable=true`. Ohne eingesteckten Stick ueberspringt `ConditionPathExists` den
Zigbee2MQTT-Container; nach dem Einstecken startet ihn
`/usr/libexec/service-containers start`.

### Rootless Mealie

Mealie ist als `127.0.0.1:15001` veroeffentlicht und unter
`mealie.home.mairhoefer.xyz` erreichbar. `PUID=0` und `PGID=0` lassen den
Einstiegspunkt ohne rekursives `chown` als Container-root laufen, also als
Host-Benutzer `mealie`. Das Subvolume `/var/lib/service-data/mealie` wird nach
`/app/data` gemountet. Registrierungen sind deaktiviert.

### Rootless OneDev

OneDev ist per HTTP als `127.0.0.1:16001` veroeffentlicht und unter
`git.home.mairhoefer.xyz` erreichbar. Git ueber SSH laeuft wie bisher auf Port
2222 aller Adressen; firewalld gibt ihn frei. Installation, HSQLDB-Datenbank und
Repositories liegen gemeinsam im Subvolume `/var/lib/service-data/onedev`, das
nach `/opt/onedev` gemountet wird; OneDev aktualisiert die Installation dort beim
Start eines neuen Images selbst.

Der Job-Executor `ServerDockerExecutor` startet Build-Container ueber den
Podman-Socket des Benutzers `onedev`, der als `/var/run/docker.sock` gemountet
wird. Das Quadlet zieht `podman.socket` dafuer als Abhaengigkeit nach. Als
einziger Container laeuft OneDev mit `SecurityLabelDisable=true`, weil
`container_t` den Socket sonst nicht erreicht. Der Socket gibt ohnehin volle
Kontrolle ueber den Podman-Zustand von `onedev`; die Grenze bildet der
unprivilegierte Host-Benutzer.


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
Backups werden als root mit `/usr/libexec/service-backup <benutzer>` gestartet,
etwa `/usr/libexec/service-backup vaultwarden`. Der Orchestrator stoppt das Target des
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

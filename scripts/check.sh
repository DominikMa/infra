#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${script_dir}/lib.sh"
failures=0

expect_machine_failure() {
    local target=$1 machine=${2-} before after
    before=$(find "${repo_root}/build" -type f 2>/dev/null | sort || true)
    if make --no-print-directory -s -C "${repo_root}" "${target}" MACHINE="${machine}" >/dev/null 2>&1; then
        echo "Fehler: make ${target} MACHINE='${machine}' haette fehlschlagen muessen." >&2
        failures=$((failures + 1))
    fi
    after=$(find "${repo_root}/build" -type f 2>/dev/null | sort || true)
    if [[ "${before}" != "${after}" ]]; then
        echo "Fehler: ungueltiges MACHINE hat Dateien erzeugt." >&2
        failures=$((failures + 1))
    fi
}

for target in ignition iso installer image publish; do
    expect_machine_failure "${target}" ""
done
expect_machine_failure ignition does-not-exist
expect_machine_failure image does-not-exist

for ignored in local/luebeck/authorized_keys build/luebeck/test.ign test.iso cosign.key; do
    if ! git -C "${repo_root}" check-ignore -q "${ignored}"; then
        echo "Fehler: ${ignored} wird nicht von .gitignore geschuetzt." >&2
        failures=$((failures + 1))
    fi
done
if git -C "${repo_root}" ls-files | grep -Eq '(^local/|^build/|\.ign$|\.iso$|^cosign\.(key|private)$)'; then
    echo "Fehler: private oder generierte Dateien sind in Git erfasst." >&2
    failures=$((failures + 1))
fi
[[ ${failures} -eq 0 ]] || exit 1

command -v podman >/dev/null || { echo "Fehler: podman wird fuer make check benoetigt." >&2; exit 1; }
for image_script in build-image.sh publish-image.sh; do
    [[ -x "${repo_root}/scripts/${image_script}" ]] || {
        echo "Fehler: scripts/${image_script} fehlt oder ist nicht ausfuehrbar." >&2
        exit 1
    }
    bash -n "${repo_root}/scripts/${image_script}"
done
smoke_script="${repo_root}/scripts/qemu-smoke.sh"
bash -n "${smoke_script}"
grep -q -- '-no-reboot' "${smoke_script}"
grep -q 'installer-serial.log' "${smoke_script}"
grep -q 'OVMF_CODE' "${smoke_script}"
grep -q 'bluebuild build --build-driver podman' "${repo_root}/scripts/build-image.sh"
grep -q 'bluebuild build --push --build-driver podman' "${repo_root}/scripts/publish-image.sh"
grep -q 'local/${machine}/image-ref' "${repo_root}/scripts/publish-image.sh"
grep -q 'COSIGN_PRIVATE_KEY' "${repo_root}/scripts/publish-image.sh"
check_dir=$(mktemp -d)
trap 'rm -rf -- "${check_dir}"' EXIT
mkdir -p "${check_dir}/build/luebeck" "${check_dir}/local/luebeck" \
    "${check_dir}/ignition/luebeck"
cp "${repo_root}/tests/fixtures/authorized_keys" "${check_dir}/local/luebeck/authorized_keys"
validate_authorized_keys "${check_dir}/local/luebeck/authorized_keys"
[[ $(grep -c '^ssh-' "${check_dir}/local/luebeck/authorized_keys") -eq 2 ]]
cp "${repo_root}/tests/fixtures/image-ref" "${check_dir}/local/luebeck/image-ref"
cp "${repo_root}/ignition/luebeck/subids" "${check_dir}/ignition/luebeck/subids"
mkdir -p "${check_dir}/files/luebeck/etc"
cp -R "${repo_root}/files/luebeck/etc/NetworkManager" \
    "${check_dir}/files/luebeck/etc/"
mkdir -p "${check_dir}/repo"
cp -R "${repo_root}/recipes" "${repo_root}/files" "${check_dir}/repo/"

podman_run -v "${repo_root}:/repo:ro" -v "${check_dir}:/files" "${BUTANE_IMAGE}" \
    --strict --pretty --files-dir /files/local/luebeck /repo/ignition/common.bu \
    > "${check_dir}/build/luebeck/common.ign"
podman_run -v "${repo_root}:/repo:ro" -v "${check_dir}:/files:ro" "${BUTANE_IMAGE}" \
    --strict --pretty --files-dir /files /repo/ignition/luebeck.bu \
    > "${check_dir}/luebeck.ign"
podman_run -v "${check_dir}/luebeck.ign:/config.ign:ro" \
    "${IGNITION_VALIDATE_IMAGE}" /config.ign

podman_run -v "${check_dir}/repo:/repo" -w /repo "${BLUEBUILD_IMAGE}" \
    /usr/bin/bluebuild generate --display-full-recipe recipes/luebeck.yml \
    > "${check_dir}/expanded-recipe.yml"

grep -q 'ostree-unverified-registry:' "${repo_root}/ignition/common.bu"
grep -q 'ostree-image-signed:docker://' "${repo_root}/ignition/common.bu"
[[ $(grep -c 'rpm-ostree rebase --bypass-driver' "${repo_root}/ignition/common.bu") -eq 2 ]]
grep -q 'Restart=on-failure' "${repo_root}/ignition/common.bu"
grep -q 'RestartSec=30s' "${repo_root}/ignition/common.bu"
grep -q '"format": "btrfs"' "${check_dir}/build/luebeck/common.ign"
grep -q '"number": 4' "${check_dir}/build/luebeck/common.ign"
grep -q '"sizeMiB": 0' "${check_dir}/build/luebeck/common.ign"
grep -q '^dest-device: /dev/nvme0n1$' "${repo_root}/installer/luebeck.yaml"
grep -q '^offline: true$' "${repo_root}/installer/luebeck.yaml"
grep -q '^copy-network: true$' "${repo_root}/installer/luebeck.yaml"
grep -q "source_iso_pattern='\*-live-iso\.\*\.iso'" "${repo_root}/scripts/build-iso.sh"
if grep -q 'provision-btrfs-user@' "${check_dir}/expanded-recipe.yml"; then
    echo "Fehler: die alte Home-Subvolume-Provisionierung ist noch aktiviert." >&2
    exit 1
fi
grep -q 'service-data.service' "${check_dir}/expanded-recipe.yml"
grep -q 'firewalld' "${check_dir}/expanded-recipe.yml"
tmpfiles_dropin="${repo_root}/files/luebeck/usr/lib/systemd/system/systemd-tmpfiles-setup.service.d/10-force-btrfs-subvolumes.conf"
grep -q '^\[Service\]$' "${tmpfiles_dropin}"
grep -q '^Environment=SYSTEMD_TMPFILES_FORCE_SUBVOL=1$' "${tmpfiles_dropin}"
[[ $(tail -n 1 "${repo_root}/recipes/luebeck.yml") == "  - type: signing" ]] || {
    echo "Fehler: signing muss das letzte Modul der luebeck-Recipe sein." >&2
    exit 1
}
grep -A1 '^alt-tags:$' "${repo_root}/recipes/luebeck.yml" | grep -q '^  - stable$'
grep -q 'local/luebeck/authorized_keys' "${repo_root}/ignition/luebeck.bu"
grep -q 'local: ignition/luebeck/subids' "${repo_root}/ignition/luebeck.bu"
[[ $(grep -c 'local: ignition/luebeck/subids' "${repo_root}/ignition/luebeck.bu") -eq 2 ]]
for subid_file in /etc/subuid /etc/subgid; do
    grep -q "path: ${subid_file}" "${repo_root}/ignition/luebeck.bu"
done
grep -q '/etc/ssh/authorized_keys/headscale' "${repo_root}/ignition/luebeck.bu"
grep -q '/etc/ssh/authorized_keys/adguard' "${repo_root}/ignition/luebeck.bu"
if grep -q '/etc/ssh/authorized_keys/caddy' "${repo_root}/ignition/luebeck.bu"; then
    echo "Fehler: caddy darf keinen SSH-Key erhalten." >&2
    exit 1
fi

sysusers="${repo_root}/files/luebeck/usr/lib/sysusers.d/service-users.conf"
grep -q '^u headscale 1010 .* /var/home/headscale /bin/fish$' "${sysusers}"
grep -q '^u caddy 1011 .* /var/home/caddy /bin/fish$' "${sysusers}"
grep -q '^u adguard 1012 .* /var/home/adguard /bin/fish$' "${sysusers}"
tmpfiles="${repo_root}/files/luebeck/usr/lib/tmpfiles.d/service-data.conf"
grep -q '^d /var/home/headscale 0750 1010 1010 -$' "${tmpfiles}"
grep -q '^d /var/home/caddy 0750 1011 1011 -$' "${tmpfiles}"
grep -q '^d /var/home/adguard 0750 1012 1012 -$' "${tmpfiles}"
grep -q '^v /var/lib/service-data/headscale 0750 1010 1010 -$' "${tmpfiles}"
grep -q '^v /var/lib/service-data/caddy 0750 1011 1011 -$' "${tmpfiles}"
grep -q '^v /var/lib/service-data/adguard 0750 1012 1012 -$' "${tmpfiles}"
grep -q '^d /var/lib/service-data/adguard/data 0750 1012 1012 -$' "${tmpfiles}"
if grep -q '/etc/container-services' "${tmpfiles}"; then
    echo "Fehler: die Image-Konfiguration darf nicht nachtraeglich durch Tmpfiles umgeschrieben werden." >&2
    exit 1
fi
grep -q '^f /var/lib/systemd/linger/headscale ' "${tmpfiles}"
grep -q '^f /var/lib/systemd/linger/caddy ' "${tmpfiles}"
grep -q '^f /var/lib/systemd/linger/adguard ' "${tmpfiles}"

subid_ignition="${repo_root}/ignition/luebeck/subids"
for expected_subid in \
    core:100000:65536 \
    headscale:200000:65536 \
    caddy:300000:65536 \
    adguard:400000:65536; do
    [[ $(grep -Fxc "${expected_subid}" "${subid_ignition}") -eq 1 ]]
done
[[ $(wc -l < "${subid_ignition}") -eq 4 ]]
if rg -n 'configure-luebeck-subids|SUBID_ROOT' \
    "${repo_root}/files" "${repo_root}/recipes" "${repo_root}/ignition"; then
    echo "Fehler: die entfernte Build-Zeit-SubID-Provisionierung wird noch referenziert." >&2
    exit 1
fi
config_owner_script="${repo_root}/files/scripts/configure-luebeck-config-ownership.sh"
[[ -x "${config_owner_script}" ]] || {
    echo "Fehler: Build-Skript fuer die Konfigurationseigentuemer fehlt." >&2
    exit 1
}
bash -n "${config_owner_script}"
for uid in 1010 1011 1012; do
    grep -q "\"${uid}:${uid}:" "${config_owner_script}"
done
grep -q 'configure-luebeck-config-ownership.sh' "${repo_root}/recipes/luebeck.yml"

network_dir="${repo_root}/files/luebeck/etc/NetworkManager"
network_profile="${network_dir}/system-connections/luebeck-lan.nmconnection"
grep -q '^type=bridge$' "${network_profile}"
grep -q '^interface-name=br0$' "${network_profile}"
grep -q '^mac-address=A8:B8:E0:05:92:E5$' "${network_profile}"
grep -q '^autoconnect-ports=1$' "${network_profile}"
grep -q '^stp=false$' "${network_profile}"
grep -q '^address1=192\.168\.7\.10/24$' "${network_profile}"
grep -q '^dns=192\.168\.7\.1;$' "${network_profile}"
grep -q '^gateway=192\.168\.7\.1$' "${network_profile}"
grep -q '^address1=2a02:8108:142b:ed00:5516:4aac:9e0a:3c00/64$' "${network_profile}"
grep -q '^address2=2a02:8108:142b:ed00:3053:ee4e:e36d:61d8/64$' "${network_profile}"
grep -q '^gateway=fe80::cece:1eff:fea9:5445$' "${network_profile}"
grep -q '^ip6-privacy=0$' "${network_profile}"
[[ $(grep -c '^method=manual$' "${network_profile}") -eq 2 ]]
for interface in enp2s0 enp3s0; do
    port_profile="${network_dir}/system-connections/luebeck-bridge-${interface}.nmconnection"
    grep -q "^interface-name=${interface}$" "${port_profile}"
    grep -q '^controller=br0$' "${port_profile}"
    grep -q '^port-type=bridge$' "${port_profile}"
    [[ $(grep -c '^method=disabled$' "${port_profile}") -eq 2 ]]
    grep -q "luebeck-bridge-${interface}.nmconnection" "${config_owner_script}"
    grep -q "local: files/luebeck/etc/NetworkManager/system-connections/luebeck-bridge-${interface}.nmconnection" \
        "${repo_root}/ignition/luebeck.bu"
done
grep -q '^mac-address=A8:B8:E0:05:92:E5$' \
    "${network_dir}/system-connections/luebeck-bridge-enp2s0.nmconnection"
grep -q '^mac-address=A8:B8:E0:05:92:E6$' \
    "${network_dir}/system-connections/luebeck-bridge-enp3s0.nmconnection"
grep -q '^no-auto-default=interface-name:enp2s0,interface-name:enp3s0$' \
    "${network_dir}/conf.d/20-luebeck-bridge.conf"
grep -q 'chmod 0600 "${network_profile}"' "${config_owner_script}"
grep -q 'local: files/luebeck/etc/NetworkManager/system-connections/luebeck-lan.nmconnection' \
    "${repo_root}/ignition/luebeck.bu"
grep -A2 'path: /etc/NetworkManager/system-connections/luebeck-lan.nmconnection' \
    "${repo_root}/ignition/luebeck.bu" | grep -q 'mode: 0600'
grep -A2 'path: /etc/NetworkManager/conf.d/20-luebeck-bridge.conf' \
    "${repo_root}/ignition/luebeck.bu" | grep -q 'mode: 0644'

ssh_config="${repo_root}/files/luebeck/etc/ssh/sshd_config.d/60-service-users.conf"
ssh_listeners="${repo_root}/files/luebeck/etc/ssh/sshd_config.d/40-listen-addresses.conf"
grep -q '^ListenAddress 0\.0\.0\.0:22$' "${ssh_listeners}"
grep -q '^ListenAddress \[2a02:8108:142b:ed00:5516:4aac:9e0a:3c00\]:22$' \
    "${ssh_listeners}"
[[ $(grep -c '^ListenAddress ' "${ssh_listeners}") -eq 2 ]]
grep -q '^Match User headscale,adguard$' "${ssh_config}"
grep -q 'AuthenticationMethods publickey' "${ssh_config}"
grep -q 'AuthorizedKeysFile /etc/ssh/authorized_keys/%u' "${ssh_config}"
grep -q 'AllowTcpForwarding no' "${ssh_config}"

headscale_quadlet="${repo_root}/files/luebeck/etc/containers/systemd/users/1010/headscale.container"
caddy_quadlet="${repo_root}/files/luebeck/etc/containers/systemd/users/1011/caddy.container"
adguard_quadlet="${repo_root}/files/luebeck/etc/containers/systemd/users/1012/adguard.container"
for quadlet in "${headscale_quadlet}" "${caddy_quadlet}" "${adguard_quadlet}"; do
    grep -q '^Restart=on-failure$' "${quadlet}"
    grep -q '^RestartSec=30s$' "${quadlet}"
    if grep -q '^SecurityLabelDisable=' "${quadlet}"; then
        echo "Fehler: SELinux-Label-Trennung darf nicht deaktiviert werden." >&2
        exit 1
    fi
done
for uid in 1010 1011 1012; do
    user_dropin="${repo_root}/files/luebeck/usr/lib/systemd/system/user@${uid}.service.d/10-service-data.conf"
    grep -q '^Requires=service-data.service$' "${user_dropin}"
    grep -q '^Wants=network-online.target$' "${user_dropin}"
    grep -q '^After=network-online.target service-data.service$' "${user_dropin}"
done
grep -q '^PublishPort=127.0.0.1:10000:8080/tcp$' \
    "${headscale_quadlet}"
grep -q '^PublishPort=127.0.0.1:10001:9090/tcp$' \
    "${headscale_quadlet}"
grep -q '^Volume=/var/lib/service-data/headscale:/var/lib/headscale:Z$' "${headscale_quadlet}"
grep -q '^Volume=/etc/container-services/headscale:/etc/headscale:ro,Z$' "${headscale_quadlet}"
grep -q '^ConditionPathExists=/etc/container-services/headscale/config.yaml$' "${headscale_quadlet}"
grep -q '^Volume=/var/lib/service-data/caddy/data:/data:Z$' "${caddy_quadlet}"
grep -q '^Volume=/var/lib/service-data/caddy/config:/config:Z$' "${caddy_quadlet}"
grep -q '^Volume=/etc/container-services/caddy:/etc/caddy:ro,Z$' "${caddy_quadlet}"
grep -q '^ConditionPathExists=/etc/container-services/caddy/Caddyfile$' "${caddy_quadlet}"
grep -q '^Image=docker.io/adguard/adguardhome:v0\.107\.79$' "${adguard_quadlet}"
grep -q '^Volume=/etc/container-services/adguard:/opt/adguardhome/conf:Z$' "${adguard_quadlet}"
grep -q '^Volume=/var/lib/service-data/adguard/data:/opt/adguardhome/work:Z$' "${adguard_quadlet}"
grep -q '^Network=adguard.network$' "${adguard_quadlet}"
for dns_mapping in \
    '0.0.0.0:53:53/tcp' \
    '0.0.0.0:53:53/udp' \
    '[::1]:53:53/tcp' \
    '[::1]:53:53/udp' \
    '[2a02:8108:142b:ed00:5516:4aac:9e0a:3c00]:53:53/tcp' \
    '[2a02:8108:142b:ed00:5516:4aac:9e0a:3c00]:53:53/udp'; do
    grep -Fqx "PublishPort=${dns_mapping}" "${adguard_quadlet}"
done
if grep -q '^PublishPort=\[::\]:53:' "${adguard_quadlet}"; then
    echo "Fehler: AdGuard DNS darf nicht auf der IPv6-Wildcard lauschen." >&2
    exit 1
fi
grep -q '^PublishPort=127\.0\.0\.1:12001:80/tcp$' "${adguard_quadlet}"
grep -q '^IPv6=true$' "${repo_root}/files/luebeck/etc/containers/systemd/users/1012/adguard.network"
grep -q '^ConditionPathExists=/etc/container-services/adguard/AdGuardHome.yaml$' "${adguard_quadlet}"
if find "${repo_root}/files/luebeck/etc/containers/systemd/users" \
    -type f -name '*.volume' -print -quit | grep -q .; then
    echo "Fehler: Service-Daten duerfen keine Podman-Named-Volumes verwenden." >&2
    exit 1
fi

container_control="${repo_root}/files/system/usr/libexec/service-containers"
[[ -x "${container_control}" ]] || {
    echo "Fehler: die gemeinsame Container-Steuerung fehlt." >&2
    exit 1
}
bash -n "${container_control}"
grep -q 'systemctl --user start containers.target' "${container_control}"
grep -q 'systemctl --user stop containers.target' "${container_control}"
for quadlet in "${headscale_quadlet}" "${caddy_quadlet}" "${adguard_quadlet}"; do
    grep -q '^PartOf=containers.target$' "${quadlet}"
    grep -q '^WantedBy=containers.target$' "${quadlet}"
done
[[ -f "${repo_root}/files/luebeck/etc/systemd/user/containers.target" ]]
[[ -L "${repo_root}/files/luebeck/etc/systemd/user/default.target.wants/containers.target" ]]
if find "${repo_root}/files/luebeck/usr/libexec" -type f \
    \( -name start -o -name stop -o -name backup \) -print -quit | grep -q .; then
    echo "Fehler: servicespezifische Lifecycle-Hooks duerfen nicht verbleiben." >&2
    exit 1
fi
grep -q '^Image=docker.io/library/caddy:2\.11\.4$' \
    "${caddy_quadlet}"
grep -q '^Network=host$' \
    "${caddy_quadlet}"
if grep -q '^ExecCondition=.*port-forward' "${caddy_quadlet}" "${adguard_quadlet}"; then
    echo "Fehler: Quadlets duerfen nicht von entfernten Port-Forward-Units abhaengen." >&2
    exit 1
fi
caddyfile="${repo_root}/files/luebeck/etc/container-services/caddy/Caddyfile"
synology_caddyfile="${repo_root}/files/luebeck/etc/container-services/caddy/services/synology.caddyfile"
grep -q '^import services/\*\.caddyfile$' "${caddyfile}"
grep -Fqx $'\tdefault_bind 0.0.0.0 [2a02:8108:142b:ed00:5516:4aac:9e0a:3c00]' \
    "${caddyfile}"
grep -q '^http:// {$' "${caddyfile}"
grep -q '^(internal_clients) {$' "${caddyfile}"
grep -q '@internal_clients remote_ip 100\.64\.0\.0/24 192\.168\.7\.0/24 2a02:8108:142b:ed00::/64 fd7a:115c:a1e0::/48' \
    "${caddyfile}"
grep -q '^calender\.synology\.mairhoefer\.xyz {' "${synology_caddyfile}"
grep -q '^contacts\.synology\.mairhoefer\.xyz {' "${synology_caddyfile}"
grep -q '^drive\.synology\.mairhoefer\.xyz {' "${synology_caddyfile}"
grep -q '^photos\.synology\.mairhoefer\.xyz {' "${synology_caddyfile}"
grep -q '^file\.synology\.mairhoefer\.xyz {' "${synology_caddyfile}"
grep -q '^synology\.home\.mairhoefer\.xyz {' "${synology_caddyfile}"
grep -q '^\s*import internal_clients$' "${synology_caddyfile}"
grep -q '^\s*handle @internal_clients {$' "${synology_caddyfile}"
adguard_caddyfile="${repo_root}/files/luebeck/etc/container-services/caddy/services/adguard.caddyfile"
grep -q '^adguard-admin\.home\.mairhoefer\.xyz {$' "${adguard_caddyfile}"
grep -q '^\s*import internal_clients$' "${adguard_caddyfile}"
grep -q '^\s*reverse_proxy 127\.0\.0\.1:12001$' "${adguard_caddyfile}"
grep -q 'reverse_proxy synology\.internal\.mairhoefer\.xyz:' "${synology_caddyfile}"
if grep -q 'header_up' "${synology_caddyfile}"; then
    echo "Fehler: redundante manuelle Proxy-Header verbleiben in der Synology-Konfiguration." >&2
    exit 1
fi
if grep -Eq '^\s*(http_port|https_port)\s' "${caddyfile}"; then
    echo "Fehler: Caddy muss direkt die Standardports 80 und 443 verwenden." >&2
    exit 1
fi
[[ -f "${repo_root}/files/luebeck/etc/container-services/headscale/config.yaml.example" ]]
[[ ! -e "${repo_root}/files/luebeck/etc/container-services/headscale/config.yaml" ]]
[[ ! -e "${repo_root}/files/luebeck/etc/container-services/caddy/Caddyfile.example" ]]
adguard_config="${repo_root}/files/luebeck/etc/container-services/adguard/AdGuardHome.yaml"
[[ -s "${adguard_config}" ]]
grep -q '^schema_version: 34$' "${adguard_config}"
grep -A3 '^  bind_hosts:$' "${adguard_config}" | grep -q '^    - 0\.0\.0\.0$'
grep -A3 '^  bind_hosts:$' "${adguard_config}" | grep -q '^    - "::"$'
[[ $(grep -A3 '^  bind_hosts:$' "${adguard_config}" | grep -c '^    - ') -eq 2 ]]
grep -A1 '^http:$' "${adguard_config}" | grep -q '^  address: 0\.0\.0\.0:80$'
[[ ! -e "${repo_root}/files/luebeck/etc/headscale" ]]
[[ ! -e "${repo_root}/files/luebeck/etc/caddy" ]]
podman_run \
    -v "${repo_root}/files/luebeck/etc/container-services/caddy:/etc/caddy:ro" \
    "${CADDY_IMAGE}" caddy validate --config /etc/caddy/Caddyfile \
    --adapter caddyfile >/dev/null
podman_run --tmpfs /tmp/adguard-work \
    -v "${repo_root}/files/luebeck/etc/container-services/adguard:/opt/adguardhome/conf:ro" \
    "${ADGUARD_IMAGE}" --check-config \
    -c /opt/adguardhome/conf/AdGuardHome.yaml -w /tmp/adguard-work >/dev/null
sysctl_config="${repo_root}/files/luebeck/etc/sysctl.d/90-unprivileged-ports.conf"
grep -q '^net\.ipv4\.ip_unprivileged_port_start = 22$' "${sysctl_config}"
firewalld_zone="${repo_root}/files/luebeck/etc/firewalld/zones/public.xml"
grep -q '<service name="ssh"/>' "${firewalld_zone}"
grep -q '<service name="dns"/>' "${firewalld_zone}"
grep -q '<service name="http"/>' "${firewalld_zone}"
grep -q '<service name="https"/>' "${firewalld_zone}"
grep -q '<port port="443" protocol="udp"/>' "${firewalld_zone}"
if rg -ni 'forward-port|11000|11001|12000' \
    "${repo_root}/files" "${repo_root}/recipes" "${repo_root}/ignition"; then
    echo "Fehler: Die entfernten Firewall-Portweiterleitungen werden noch referenziert." >&2
    exit 1
fi
backup_orchestrator="${repo_root}/files/system/usr/libexec/service-backup"
[[ -x "${backup_orchestrator}" ]] || {
    echo "Fehler: der Root-Backup-Orchestrator fehlt oder ist nicht ausfuehrbar." >&2
    exit 1
}
bash -n "${backup_orchestrator}"
grep -q 'run_borg_backup' "${backup_orchestrator}"
if grep -Eq '\b(tar|zip)\b' "${backup_orchestrator}"; then
    echo "Fehler: der Backup-Orchestrator darf kein ZIP- oder TAR-Archiv erzeugen." >&2
    exit 1
fi
"${backup_orchestrator}" 'invalid/service' >/dev/null 2>&1 && {
    echo "Fehler: Backup-Orchestrator akzeptiert einen ungueltigen Benutzernamen." >&2
    exit 1
}
verify_data="${repo_root}/files/luebeck/usr/libexec/verify-service-data"
[[ -x "${verify_data}" ]] || { echo "Fehler: Subvolume-Pruefung fehlt." >&2; exit 1; }
bash -n "${verify_data}"
if rg -n 'provision-btrfs-user|home_headscale|home_caddy|backup-btrfs-user' \
    "${repo_root}/files" "${repo_root}/recipes" "${repo_root}/ignition"; then
    echo "Fehler: Referenzen auf die alte Home-Subvolume-Architektur verbleiben." >&2
    exit 1
fi
if rg -ni 'bluebuild' "${repo_root}/files" "${repo_root}/ignition"; then
    echo "Fehler: BlueBuild-Namensreste wuerden in das Laufzeit-Image gelangen." >&2
    exit 1
fi

quadlet_generator=/usr/lib/systemd/system-generators/podman-system-generator
if [[ -x "${quadlet_generator}" ]]; then
    QUADLET_UNIT_DIRS="${repo_root}/files/luebeck/etc/containers/systemd/users/1010" \
        "${quadlet_generator}" --user --dryrun >/dev/null
    QUADLET_UNIT_DIRS="${repo_root}/files/luebeck/etc/containers/systemd/users/1011" \
        "${quadlet_generator}" --user --dryrun >/dev/null
    QUADLET_UNIT_DIRS="${repo_root}/files/luebeck/etc/containers/systemd/users/1012" \
        "${quadlet_generator}" --user --dryrun >/dev/null
fi

echo "Alle Konfigurationen und Schutzregeln sind gueltig."

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

for target in ignition iso installer; do
    expect_machine_failure "${target}" ""
done
expect_machine_failure ignition does-not-exist

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
check_dir=$(mktemp -d)
trap 'rm -rf -- "${check_dir}"' EXIT
mkdir -p "${check_dir}/build/luebeck" "${check_dir}/local/luebeck"
cp "${repo_root}/tests/fixtures/authorized_keys" "${check_dir}/local/luebeck/authorized_keys"
cp "${repo_root}/tests/fixtures/image-ref" "${check_dir}/local/luebeck/image-ref"
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
[[ $(tail -n 1 "${repo_root}/recipes/luebeck.yml") == "  - type: signing" ]] || {
    echo "Fehler: signing muss das letzte Modul der luebeck-Recipe sein." >&2
    exit 1
}
grep -q 'local/luebeck/authorized_keys' "${repo_root}/ignition/luebeck.bu"
grep -q '/etc/ssh/authorized_keys/headscale' "${repo_root}/ignition/luebeck.bu"
grep -q '/etc/ssh/authorized_keys/adguard' "${repo_root}/ignition/luebeck.bu"
if grep -q '/etc/ssh/authorized_keys/caddy' "${repo_root}/ignition/luebeck.bu"; then
    echo "Fehler: caddy darf keinen SSH-Key erhalten." >&2
    exit 1
fi

sysusers="${repo_root}/files/luebeck/usr/lib/sysusers.d/service-users.conf"
grep -q '^u headscale 1010 .* /var/home/headscale /bin/bash$' "${sysusers}"
grep -q '^u caddy 1011 .* /var/home/caddy /usr/sbin/nologin$' "${sysusers}"
grep -q '^u adguard 1012 .* /var/home/adguard /bin/bash$' "${sysusers}"
tmpfiles="${repo_root}/files/luebeck/usr/lib/tmpfiles.d/service-data.conf"
grep -q '^d /var/home/headscale 0750 1010 1010 -$' "${tmpfiles}"
grep -q '^d /var/home/caddy 0750 1011 1011 -$' "${tmpfiles}"
grep -q '^d /var/home/adguard 0750 1012 1012 -$' "${tmpfiles}"
grep -q '^v /var/lib/service-data/headscale 0750 1010 1010 -$' "${tmpfiles}"
grep -q '^v /var/lib/service-data/caddy 0750 1011 1011 -$' "${tmpfiles}"
grep -q '^v /var/lib/service-data/adguard 0750 1012 1012 -$' "${tmpfiles}"
grep -q '^d /var/lib/service-data/adguard/data 0750 1012 1012 -$' "${tmpfiles}"
grep -q '^d /etc/container-services/adguard 0750 1012 1012 -$' "${tmpfiles}"
grep -q '^z /etc/container-services/adguard/AdGuardHome.yaml 0640 1012 1012 -$' "${tmpfiles}"
grep -q '^f /var/lib/systemd/linger/headscale ' "${tmpfiles}"
grep -q '^f /var/lib/systemd/linger/caddy ' "${tmpfiles}"
grep -q '^f /var/lib/systemd/linger/adguard ' "${tmpfiles}"

subid_script="${repo_root}/files/scripts/configure-luebeck-subids.sh"
[[ -x "${subid_script}" ]] || { echo "Fehler: SubID-Build-Skript fehlt." >&2; exit 1; }
bash -n "${subid_script}"
grep -q 'headscale 200000 65536' "${subid_script}"
grep -q 'caddy 300000 65536' "${subid_script}"
grep -q 'adguard 400000 65536' "${subid_script}"
mkdir -p "${check_dir}/subids/etc"
printf '%s\n' 'core:100000:65536' > "${check_dir}/subids/etc/subuid"
printf '%s\n' 'core:100000:65536' > "${check_dir}/subids/etc/subgid"
SUBID_ROOT="${check_dir}/subids" "${subid_script}"
SUBID_ROOT="${check_dir}/subids" "${subid_script}"
for subid_file in subuid subgid; do
    grep -qx 'core:100000:65536' "${check_dir}/subids/etc/${subid_file}"
    [[ $(grep -xc 'headscale:200000:65536' "${check_dir}/subids/etc/${subid_file}") -eq 1 ]]
    [[ $(grep -xc 'caddy:300000:65536' "${check_dir}/subids/etc/${subid_file}") -eq 1 ]]
    [[ $(grep -xc 'adguard:400000:65536' "${check_dir}/subids/etc/${subid_file}") -eq 1 ]]
done

ssh_config="${repo_root}/files/luebeck/etc/ssh/sshd_config.d/60-service-users.conf"
grep -q '^Match User headscale,adguard$' "${ssh_config}"
grep -q 'AuthenticationMethods publickey' "${ssh_config}"
grep -q 'AuthorizedKeysFile /etc/ssh/authorized_keys/%u' "${ssh_config}"
grep -q 'AllowTcpForwarding no' "${ssh_config}"

headscale_quadlet="${repo_root}/files/luebeck/etc/containers/systemd/users/1010/headscale.container"
caddy_quadlet="${repo_root}/files/luebeck/etc/containers/systemd/users/1011/caddy.container"
adguard_quadlet="${repo_root}/files/luebeck/etc/containers/systemd/users/1012/adguard.container"
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
grep -q '^PublishPort=12000:53/tcp$' "${adguard_quadlet}"
grep -q '^PublishPort=12000:53/udp$' "${adguard_quadlet}"
grep -q '^PublishPort=127.0.0.1:12001:80/tcp$' "${adguard_quadlet}"
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
grep -q '^(internal_clients) {$' "${caddyfile}"
grep -q '@internal_clients remote_ip 100\.64\.0\.0/24 192\.168\.7\.0/24' "${caddyfile}"
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
grep -q 'http_port 11000' \
    "${caddyfile}"
grep -q 'https_port 11001' \
    "${caddyfile}"
[[ -f "${repo_root}/files/luebeck/etc/container-services/headscale/config.yaml.example" ]]
[[ ! -e "${repo_root}/files/luebeck/etc/container-services/headscale/config.yaml" ]]
[[ ! -e "${repo_root}/files/luebeck/etc/container-services/caddy/Caddyfile.example" ]]
adguard_config="${repo_root}/files/luebeck/etc/container-services/adguard/AdGuardHome.yaml"
[[ -s "${adguard_config}" ]]
grep -q '^schema_version: 34$' "${adguard_config}"
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
firewalld_zone="${repo_root}/files/luebeck/etc/firewalld/zones/public.xml"
grep -q '<forward-port port="80" protocol="tcp" to-port="11000"/>' "${firewalld_zone}"
grep -q '<forward-port port="443" protocol="tcp" to-port="11001"/>' "${firewalld_zone}"
grep -q '<forward-port port="443" protocol="udp" to-port="11001"/>' "${firewalld_zone}"
grep -q '<forward-port port="53" protocol="tcp" to-port="12000"/>' "${firewalld_zone}"
grep -q '<forward-port port="53" protocol="udp" to-port="12000"/>' "${firewalld_zone}"
[[ $(grep -c '<rule family="ipv6">' "${firewalld_zone}") -eq 5 ]]
grep -q '<service name="ssh"/>' "${firewalld_zone}"
if find "${repo_root}/files/luebeck" -type f \
    \( -name '*port-forward.service' -o -name '*.nft' \) -print -quit | grep -q .; then
    echo "Fehler: Portweiterleitungen muessen ausschliesslich in firewalld liegen." >&2
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

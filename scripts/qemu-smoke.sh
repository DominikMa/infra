#!/usr/bin/env bash
set -euo pipefail

machine=${1-}
ssh_key=${2-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"${script_dir}/validate-machine.sh" "${machine}"
source "${script_dir}/lib.sh"
validate_local_inputs "${machine}"

if [[ -z "${ssh_key}" || ! -f "${ssh_key}" ]]; then
    echo "Fehler: SSH_KEY muss auf den privaten Schluessel zum authorized_keys-Eintrag zeigen." >&2
    exit 2
fi
for command in qemu-system-x86_64 qemu-img ssh timeout; do
    command -v "${command}" >/dev/null || { echo "Fehler: ${command} fehlt." >&2; exit 2; }
done

ovmf_code=${OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.fd}
ovmf_vars_template=${OVMF_VARS:-/usr/share/edk2/ovmf/OVMF_VARS.fd}
for firmware in "${ovmf_code}" "${ovmf_vars_template}"; do
    if [[ ! -f "${firmware}" ]]; then
        echo "Fehler: OVMF-Firmware fehlt: ${firmware}" >&2
        exit 2
    fi
done

iso="${repo_root}/build/${machine}/${machine}-installer.iso"
if [[ ! -s "${iso}" ]]; then
    make --no-print-directory -C "${repo_root}" installer MACHINE="${machine}"
fi

vm_dir="${repo_root}/build/${machine}/smoke"
disk="${vm_dir}/${machine}.qcow2"
installer_serial_log="${vm_dir}/installer-serial.log"
serial_log="${vm_dir}/serial.log"
ovmf_vars="${vm_dir}/OVMF_VARS.fd"
mkdir -p "${vm_dir}"
rm -f -- "${disk}" "${installer_serial_log}" "${serial_log}" "${ovmf_vars}"
qemu-img create -q -f qcow2 "${disk}" 20G
cp --reflink=auto "${ovmf_vars_template}" "${ovmf_vars}"

qemu_accel=${QEMU_ACCEL:-kvm}
qemu_common=(
    -name "fcos-${machine}-smoke" -machine "q35,accel=${qemu_accel}"
    -cpu host -smp 2 -m 4096 -display none
    -drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}"
    -drive "if=pflash,format=raw,file=${ovmf_vars}"
    -drive "if=none,id=nvme0,file=${disk},format=qcow2"
    -device nvme,drive=nvme0,serial=smoke-nvme
    -device virtio-net-pci,netdev=net0
)

qemu_pid=
cleanup() {
    if [[ -n "${qemu_pid}" ]]; then
        kill "${qemu_pid}" 2>/dev/null || true
        wait "${qemu_pid}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "Installiere FCOS vom ISO (maximal 15 Minuten) ..."
qemu-system-x86_64 \
    "${qemu_common[@]}" -serial "file:${installer_serial_log}" \
    -netdev user,id=net0 \
    -drive "file=${iso},media=cdrom,readonly=on" -boot once=d \
    -no-reboot &
qemu_pid=$!

if ! timeout 900 bash -c '
    while kill -0 "$1" 2>/dev/null; do
        sleep 1
    done
' _ "${qemu_pid}"; then
    echo "Smoke-Test fehlgeschlagen: Installation dauerte zu lange. Serielle Ausgabe: ${installer_serial_log}" >&2
    exit 1
fi
if wait "${qemu_pid}"; then
    installer_status=0
else
    installer_status=$?
fi
qemu_pid=
if [[ ${installer_status} -ne 0 ]]; then
    echo "Smoke-Test fehlgeschlagen: Installer-QEMU endete mit Status ${installer_status}. Serielle Ausgabe: ${installer_serial_log}" >&2
    exit 1
fi

echo "Starte das installierte System ohne Installer-ISO ..."
qemu-system-x86_64 \
    "${qemu_common[@]}" -serial "file:${serial_log}" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -boot order=c &
qemu_pid=$!

image_ref=$(tr -d '\n' < "${repo_root}/local/${machine}/image-ref")
ssh_opts=(-i "${ssh_key}" -p 2222 -o BatchMode=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

echo "Warte auf beide Rebase-Neustarts (maximal 30 Minuten) ..."
timeout 1800 bash -c '
    while kill -0 "$1" 2>/dev/null; do
        if ssh "${@:3}" core@127.0.0.1 \
            "test \"\$(hostname)\" = luebeck &&
             test \"\$(findmnt -n -o FSTYPE /sysroot)\" = btrfs &&
             ip -4 route show default | grep -q . &&
             test \"\$(id -u caddy)\" = 1011 &&
             test \"\$(id -u headscale)\" = 1010 &&
             test \"\$(id -u adguard)\" = 1012 &&
             test \"\$(getent passwd headscale | cut -d: -f6-7)\" = /var/home/headscale:/bin/fish &&
             test \"\$(getent passwd caddy | cut -d: -f6-7)\" = /var/home/caddy:/bin/fish &&
             test \"\$(getent passwd adguard | cut -d: -f6-7)\" = /var/home/adguard:/bin/fish &&
             ! mountpoint -q /var/home/headscale &&
             ! mountpoint -q /var/home/caddy &&
             ! mountpoint -q /var/home/adguard &&
             sudo btrfs subvolume show /var/lib/service-data/headscale >/dev/null &&
             sudo btrfs subvolume show /var/lib/service-data/caddy >/dev/null &&
             sudo btrfs subvolume show /var/lib/service-data/adguard >/dev/null &&
             test -f /etc/containers/systemd/users/1010/headscale.container &&
             test -f /etc/containers/systemd/users/1011/caddy.container &&
             test -f /etc/containers/systemd/users/1012/adguard.container &&
             test -f /etc/systemd/user/containers.target &&
             test -L /etc/systemd/user/default.target.wants/containers.target &&
             test -f /var/lib/systemd/linger/headscale &&
             test -f /var/lib/systemd/linger/caddy &&
             test -f /var/lib/systemd/linger/adguard &&
             systemctl is-enabled --quiet firewalld.service &&
             sudo firewall-cmd --zone=public --query-service=dns &&
             sudo firewall-cmd --zone=public --query-service=http &&
             sudo firewall-cmd --zone=public --query-service=https &&
             sudo firewall-cmd --zone=public --query-port=443/udp &&
             test "\$(sysctl -n net.ipv4.ip_unprivileged_port_start)" = 22 &&
             test -e /var/lib/image-rebase/signed-requested &&
             rpm-ostree status --json | jq -e --arg ref \"$2\" \
               '\''any(.deployments[]; .booted and .origin == (\"ostree-image-signed:docker://\" + \$ref))'\''" \
             >/dev/null 2>&1; then
            exit 0
        fi
        sleep 10
    done
    exit 1
' _ "${qemu_pid}" "${image_ref}" "${ssh_opts[@]}" || {
    echo "Smoke-Test fehlgeschlagen. Serielle Ausgabe: ${serial_log}" >&2
    exit 1
}

ssh "${ssh_opts[@]}" headscale@127.0.0.1 'test "$(id -u)" = 1010' || {
    echo "Smoke-Test fehlgeschlagen: SSH-Login fuer headscale funktioniert nicht." >&2
    exit 1
}
ssh "${ssh_opts[@]}" adguard@127.0.0.1 'test "$(id -u)" = 1012' || {
    echo "Smoke-Test fehlgeschlagen: SSH-Login fuer adguard funktioniert nicht." >&2
    exit 1
}
if ssh "${ssh_opts[@]}" caddy@127.0.0.1 true >/dev/null 2>&1; then
    echo "Smoke-Test fehlgeschlagen: caddy darf keinen SSH-Login erlauben." >&2
    exit 1
fi
ssh "${ssh_opts[@]}" core@127.0.0.1 \
    'echo "# smoke drift" | sudo tee -a /etc/container-services/caddy/Caddyfile >/dev/null &&
     sudo ostree admin config-diff | grep -Eq "M[[:space:]]+container-services/caddy/Caddyfile" &&
     sudo /usr/libexec/service-backup caddy | grep -q "Borg placeholder"' || {
    echo "Smoke-Test fehlgeschlagen: config-diff oder Daten-Backup ist fehlerhaft." >&2
    exit 1
}

echo "Smoke-Test erfolgreich: Installation, deklarative Benutzer, Daten-Subvolumes, SSH, Drift und Backup verifiziert."

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

iso="${repo_root}/build/${machine}/${machine}-installer.iso"
if [[ ! -s "${iso}" ]]; then
    make --no-print-directory -C "${repo_root}" installer MACHINE="${machine}"
fi

vm_dir="${repo_root}/build/${machine}/smoke"
disk="${vm_dir}/${machine}.qcow2"
serial_log="${vm_dir}/serial.log"
mkdir -p "${vm_dir}"
rm -f -- "${disk}" "${serial_log}"
qemu-img create -q -f qcow2 "${disk}" 20G

qemu_accel=${QEMU_ACCEL:-kvm}
qemu-system-x86_64 \
    -name "fcos-${machine}-smoke" -machine q35,accel="${qemu_accel}" \
    -cpu host -smp 2 -m 4096 -display none -serial "file:${serial_log}" \
    -drive "if=none,id=nvme0,file=${disk},format=qcow2" \
    -device nvme,drive=nvme0,serial=smoke-nvme \
    -drive "file=${iso},media=cdrom,readonly=on" -boot order=c,once=d \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device virtio-net-pci,netdev=net0 &
qemu_pid=$!
cleanup() { kill "${qemu_pid}" 2>/dev/null || true; wait "${qemu_pid}" 2>/dev/null || true; }
trap cleanup EXIT

image_ref=$(tr -d '\n' < "${repo_root}/local/${machine}/image-ref")
ssh_opts=(-i "${ssh_key}" -p 2222 -o BatchMode=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

echo "Warte auf Installation und beide Rebase-Neustarts (maximal 30 Minuten) ..."
timeout 1800 bash -c '
    while kill -0 "$1" 2>/dev/null; do
        if ssh "${@:3}" core@127.0.0.1 \
            "test \"\$(hostname)\" = luebeck &&
             test \"\$(findmnt -n -o FSTYPE /sysroot)\" = btrfs &&
             ip -4 route show default | grep -q . &&
             test -e /var/lib/bluebuild-rebase/signed-requested &&
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

echo "Smoke-Test erfolgreich: NVMe-Installation, Btrfs, DHCP/SSH und signierter Origin verifiziert."

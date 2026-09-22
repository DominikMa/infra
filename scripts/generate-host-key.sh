#!/usr/bin/env bash
set -euo pipefail

machine=${1-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"${script_dir}/validate-machine.sh" "${machine}"
source "${script_dir}/lib.sh"

key_dir="${repo_root}/local/${machine}/host_key"
private_key="${key_dir}/ssh_host_ed25519_key"
public_key="${private_key}.pub"

if [[ -e "${private_key}" || -e "${public_key}" ]]; then
    echo "Fehler: Ein SSH-Host-Key fuer ${machine} existiert bereits; nichts wurde ueberschrieben." >&2
    exit 2
fi

umask 077
mkdir -p "${key_dir}"
temporary_dir=$(mktemp -d "${key_dir}/.host-key.XXXXXX")
trap 'rm -rf -- "${temporary_dir}"' EXIT

ssh-keygen -q -t ed25519 -N '' -C "root@${machine}" \
    -f "${temporary_dir}/ssh_host_ed25519_key"
install -m 0600 "${temporary_dir}/ssh_host_ed25519_key" "${private_key}"
install -m 0644 "${temporary_dir}/ssh_host_ed25519_key.pub" "${public_key}"

echo "Erzeugt: local/${machine}/host_key/ssh_host_ed25519_key"
ssh-keygen -lf "${public_key}"

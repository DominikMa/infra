#!/usr/bin/env bash
set -euo pipefail

machine=${1-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"${script_dir}/validate-machine.sh" "${machine}"
source "${script_dir}/lib.sh"
source "${script_dir}/machine-config.sh"
machine_config "${machine}"
validate_local_inputs "${machine}"

ignition="${repo_root}/build/${machine}/${machine}.ign"
if [[ ! -s "${ignition}" ]]; then
    echo "Fehler: ${ignition} fehlt; zuerst 'make ignition MACHINE=${machine}' ausfuehren." >&2
    exit 2
fi

output_dir="${repo_root}/build/${machine}"
download_dir="${output_dir}/fcos-live"
output_iso="${output_dir}/${machine}-installer.iso"
source_iso_pattern='*-live-iso.*.iso'
mkdir -p "${download_dir}"

if ! find "${download_dir}" -maxdepth 1 -type f -name "${source_iso_pattern}" -print -quit | grep -q .; then
    podman_run -v "${download_dir}:/data" "${COREOS_INSTALLER_IMAGE}" \
        download --stream stable --architecture "${MACHINE_ARCH}" \
        --platform metal --format iso --directory /data
fi

mapfile -t source_isos < <(find "${download_dir}" -maxdepth 1 -type f -name "${source_iso_pattern}" -print | sort)
if [[ ${#source_isos[@]} -ne 1 ]]; then
    echo "Fehler: erwartet genau ein FCOS-Live-ISO in ${download_dir}, gefunden: ${#source_isos[@]}." >&2
    exit 2
fi

rm -f -- "${output_iso}"
podman_run -v "${repo_root}:/work:ro" -v "${output_dir}:/output" \
    -v "${source_isos[0]}:/input.iso:ro" "${COREOS_INSTALLER_IMAGE}" \
    iso customize --dest-ignition "/work/build/${machine}/${machine}.ign" \
    --installer-config "/work/installer/${machine}.yaml" \
    --output "/output/${machine}-installer.iso" /input.iso

echo "Erzeugt: build/${machine}/${machine}-installer.iso"

#!/usr/bin/env bash
set -euo pipefail

machine=${1-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"${script_dir}/validate-machine.sh" "${machine}"
source "${script_dir}/lib.sh"
validate_local_inputs "${machine}"

output_dir="${repo_root}/build/${machine}"
mkdir -p "${output_dir}"

podman_run -v "${repo_root}:/work:ro" \
    -v "${repo_root}/local/${machine}:/machine-local:ro" "${BUTANE_IMAGE}" \
    --strict --pretty --files-dir /machine-local /work/ignition/common.bu \
    > "${output_dir}/common.ign"

podman_run -v "${repo_root}:/work:ro" \
    "${BUTANE_IMAGE}" --strict --pretty --files-dir /work \
    "/work/ignition/${machine}.bu" > "${output_dir}/${machine}.ign"

podman_run -v "${output_dir}/${machine}.ign:/config.ign:ro" \
    "${IGNITION_VALIDATE_IMAGE}" /config.ign

echo "Erzeugt: build/${machine}/${machine}.ign"

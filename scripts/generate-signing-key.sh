#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${script_dir}/lib.sh"

if [[ -e "${repo_root}/cosign.key" || -e "${repo_root}/cosign.pub" ]]; then
    echo "Fehler: cosign.key oder cosign.pub existiert bereits; nichts wurde ueberschrieben." >&2
    exit 2
fi

podman run --rm --security-opt label=disable -it --userns=keep-id \
    --user "$(id -u):$(id -g)" \
    -v "${repo_root}:/keys" -w /keys "${COSIGN_IMAGE}" generate-key-pair

echo "cosign.pub committen; cosign.key als GitHub-Secret SIGNING_SECRET hinterlegen."

#!/usr/bin/env bash

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

BUTANE_IMAGE=${BUTANE_IMAGE:-quay.io/coreos/butane:release}
IGNITION_VALIDATE_IMAGE=${IGNITION_VALIDATE_IMAGE:-quay.io/coreos/ignition-validate:release}
COREOS_INSTALLER_IMAGE=${COREOS_INSTALLER_IMAGE:-quay.io/coreos/coreos-installer:release}
BLUEBUILD_IMAGE=${BLUEBUILD_IMAGE:-ghcr.io/blue-build/cli:v0.9.37}
COSIGN_IMAGE=${COSIGN_IMAGE:-cgr.dev/chainguard/cosign:latest}

podman_run() {
    podman run --rm --security-opt label=disable --userns=keep-id "$@"
}

validate_local_inputs() {
    local machine=$1 key_file image_file image_ref
    key_file="${repo_root}/local/${machine}/authorized_keys"
    image_file="${repo_root}/local/${machine}/image-ref"
    if [[ ! -s "${key_file}" ]]; then
        echo "Fehler: ${key_file} fehlt oder ist leer." >&2
        return 2
    fi
    if ! grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh.com) [A-Za-z0-9+/]+={0,3}([[:space:]].*)?$' "${key_file}"; then
        echo "Fehler: ${key_file} enthaelt keinen gueltig aussehenden OpenSSH-Schluessel." >&2
        return 2
    fi
    if [[ ! -s "${image_file}" ]]; then
        echo "Fehler: ${image_file} fehlt oder ist leer." >&2
        return 2
    fi
    image_ref=$(tr -d '\n' < "${image_file}")
    if [[ $(wc -l < "${image_file}") -ne 1 ]] ||
       [[ ! "${image_ref}" =~ ^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] ||
       [[ "${image_ref}" == *'<'* ]] || [[ "${image_ref}" == *'>'* ]]; then
        echo "Fehler: ${image_file} muss genau eine OCI-Referenz wie ghcr.io/owner/${machine}:stable enthalten." >&2
        return 2
    fi
}

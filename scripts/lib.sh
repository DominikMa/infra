#!/usr/bin/env bash

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

BUTANE_IMAGE=${BUTANE_IMAGE:-quay.io/coreos/butane:release}
IGNITION_VALIDATE_IMAGE=${IGNITION_VALIDATE_IMAGE:-quay.io/coreos/ignition-validate:release}
COREOS_INSTALLER_IMAGE=${COREOS_INSTALLER_IMAGE:-quay.io/coreos/coreos-installer:release}
BLUEBUILD_IMAGE=${BLUEBUILD_IMAGE:-ghcr.io/blue-build/cli:v0.9.37}
COSIGN_IMAGE=${COSIGN_IMAGE:-cgr.dev/chainguard/cosign:latest}
CADDY_IMAGE=${CADDY_IMAGE:-docker.io/library/caddy:2.11.4}
ADGUARD_IMAGE=${ADGUARD_IMAGE:-docker.io/adguard/adguardhome:v0.107.79}

podman_run() {
    podman run --rm --security-opt label=disable --userns=keep-id "$@"
}

validate_authorized_keys() {
    local key_file=$1 key_count=0 line
    local key_pattern='^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh.com) [A-Za-z0-9+/]+={0,3}([[:space:]].*)?$'

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        if [[ ! "${line}" =~ ${key_pattern} ]] ||
           ! ssh-keygen -l -f - <<<"${line}" >/dev/null 2>&1; then
            return 1
        fi
        key_count=$((key_count + 1))
    done < "${key_file}"

    [[ ${key_count} -ge 1 ]]
}

validate_ssh_host_key_pair() {
    local private_key=$1 public_key=$2 private_mode
    local derived_type derived_data public_type public_data remainder

    [[ -s "${private_key}" && -s "${public_key}" ]] || return 1

    private_mode=$(stat -c '%a' "${private_key}") || return 1
    (( (8#${private_mode} & 8#077) == 0 )) || return 1

    read -r derived_type derived_data remainder <<<"$(ssh-keygen -y -f "${private_key}" 2>/dev/null)"
    read -r public_type public_data remainder < "${public_key}"
    [[ "${derived_type}" == ssh-ed25519 && "${public_type}" == ssh-ed25519 &&
       -n "${derived_data}" && "${derived_data}" == "${public_data}" ]]
}

validate_local_inputs() {
    local machine=$1 key_file image_file image_ref host_private host_public
    key_file="${repo_root}/local/${machine}/authorized_keys"
    image_file="${repo_root}/local/${machine}/image-ref"
    host_private="${repo_root}/local/${machine}/host_key/ssh_host_ed25519_key"
    host_public="${host_private}.pub"
    if [[ ! -s "${key_file}" ]]; then
        echo "Fehler: ${key_file} fehlt oder ist leer." >&2
        return 2
    fi
    if ! validate_authorized_keys "${key_file}"; then
        echo "Fehler: ${key_file} muss mindestens einen gueltigen OpenSSH-Schluessel enthalten." >&2
        return 2
    fi
    if ! validate_ssh_host_key_pair "${host_private}" "${host_public}"; then
        echo "Fehler: ${host_private} und ${host_public} muessen ein passendes Ed25519-Host-Key-Paar sein; der private Schluessel darf keine Gruppen- oder Weltrechte haben." >&2
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

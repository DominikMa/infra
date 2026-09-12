#!/usr/bin/env bash

machine_config() {
    case "$1" in
        luebeck)
            MACHINE_ARCH=x86_64
            MACHINE_DEVICE=/dev/nvme0n1
            ;;
        *) return 1 ;;
    esac
}

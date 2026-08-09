#!/bin/bash
# Runs unit tests for the pure clustering logic.
set -euo pipefail
cd "$(dirname "$0")"
source ./clt-workaround.sh
mkdir -p .build
swiftc "${SWIFT_EXTRA_FLAGS[@]}" -o .build/tests \
    Sources/WhittleCore/ClusterEngine.swift Tests/main.swift
./.build/tests

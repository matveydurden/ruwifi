#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../vendor/sing-box"
go build -trimpath -tags with_gvisor,with_clash_api -ldflags '-s -w -X github.com/sagernet/sing-box/constant.Version=1.14.2-ruwifi.1' -o ../../app/.build/sing-box ./cmd/sing-box

#!/usr/bin/env bash
set -euo pipefail

nomad-pack run . -var "enable_batch_verification=true"

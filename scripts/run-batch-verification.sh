#!/usr/bin/env bash
set -euo pipefail

nomad-pack run --name openstudio-server-batch-verify -var "enable_batch_verification=true" packs/openstudio-server

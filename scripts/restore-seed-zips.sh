#!/bin/bash
# Restore seed zips to web NFS from worker local disk copies.
# Chunked transfer: exec output caps ~191KB, stdin accepts >1MB.
# Usage: ./restore-seed-zips.sh <analysis_id> <zip_filename>
set -u
WORKDIR=/tmp/oss-recovery
mkdir -p "$WORKDIR"
ID="$1"
ZIPNAME="$2"
WEB_ALLOC=0e975d1e
WORKER_ALLOC=0004c6e1
SRC=/mnt/openstudio/analysis_${ID}/analysis.zip
DEST_DIR=/mnt/openstudio/server/assets/analyses/${ID}/original
DEST="${DEST_DIR}/${ZIPNAME}"

# 1. Pull base64 chunks from worker (each under 191KB exec output cap)
rm -f "${WORKDIR}/${ID}_chunk_"*.b64
i=0
while :; do
  OUT=$(NOMAD_ADDR=http://10.60.126.125:4646 nomad alloc exec -task=worker "$WORKER_ALLOC" \
    sh -c "dd if=${SRC} bs=140000 skip=${i} count=1 2>/dev/null | base64" 2>/dev/null)
  if [ -z "$OUT" ]; then
    # last chunk may be empty only if file size is exact multiple
    if [ "$i" -eq 0 ]; then echo "ERROR: no output for chunk $i"; exit 1; fi
    break
  fi
  printf '%s\n' "$OUT" > "${WORKDIR}/${ID}_chunk_${i}.b64"
  SIZE=$(wc -c < "${WORKDIR}/${ID}_chunk_${i}.b64")
  if [ "$SIZE" -lt 100 ]; then rm -f "${WORKDIR}/${ID}_chunk_${i}.b64"; break; fi
  i=$((i+1))
done
echo "pulled $i chunks"

# 2. Assemble + decode locally
cat "${WORKDIR}/${ID}_chunk_"*.b64 > "${WORKDIR}/${ID}.all.b64"
base64 -D -i "${WORKDIR}/${ID}.all.b64" -o "${WORKDIR}/${ID}.zip" || { echo "base64 decode failed"; exit 1; }
LOCAL_SIZE=$(stat -f "%z" "${WORKDIR}/${ID}.zip")

# 3. Verify against worker source sha256
SRC_SHA=$(NOMAD_ADDR=http://10.60.126.125:4646 nomad alloc exec -task=worker "$WORKER_ALLOC" sh -c "shasum -a 256 ${SRC}" 2>/dev/null | awk '{print $1}')
LOCAL_SHA=$(shasum -a 256 "${WORKDIR}/${ID}.zip" | awk '{print $1}')
if [ "$SRC_SHA" != "$LOCAL_SHA" ]; then
  echo "ERROR: sha256 mismatch src=${SRC_SHA} local=${LOCAL_SHA}"; exit 1
fi
echo "sha256 OK ($LOCAL_SIZE bytes)"

# 4. Push to web NFS via stdin
NOMAD_ADDR=http://10.60.126.125:4646 nomad alloc exec -task=web "$WEB_ALLOC" \
  sh -c "mkdir -p ${DEST_DIR}" 2>/dev/null
base64 -i "${WORKDIR}/${ID}.zip" | NOMAD_ADDR=http://10.60.126.125:4646 nomad alloc exec -i -task=web "$WEB_ALLOC" \
  sh -c "base64 -d > ${DEST} && stat -c '%s' ${DEST}" 2>&1 | tail -1

# 5. Verify endpoint
NOMAD_ADDR=http://10.60.126.125:4646 nomad alloc exec -task=web "$WEB_ALLOC" \
  sh -c "curl -s -o /dev/null -w 'HTTP %{http_code} size=%{size_download}\n' http://localhost/analyses/${ID}/download_analysis_zip" 2>&1 | tail -1
echo "=== done: ${ID} ==="

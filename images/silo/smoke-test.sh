#!/bin/bash
# Smoke test for the silo image: ADR-0026's contract, on the site's own build.
#
# Stands the built image up in a throwaway container and checks each guarantee
# the contract asks of the engine itself. Run it after every version bump; it is
# the regression test for an engine change (ADR-0026 §1).
#
#   1  a second If-None-Match: * PUT returns 412, atomically, on a versioned bucket
#   2  a confined key is refused outside its prefix or bucket; a read-only key every write
#   3  a bucket quota: a single-part upload larger than it is refused at once;
#      past it, writes are refused once the scanner has counted the bucket (see
#      below). A multipart upload is counted only after it completes.
#   4  versioning, switchable
#   5  lifecycle rules: current and noncurrent expiry
#   7  the admin API: everything above is set up through it (mc admin, madmin)
#   9  anonymous GetObject on one bucket, and nothing else anonymously
#
# Checks 6 (TLS) and 8 (offline, no licence check) are not the image's: the
# service proxy holds the certificate, and 8 is the licence and the staged
# tarball. CHG-0068 checks both on the host.
#
# COMPAT=1 also rehearses CHG-0068's state move: MinIO writes a versioned
# bucket, a confined user and its policy into a data directory, then this image
# starts on the same directory and must read every one back. It needs the
# MinIO image the site runs, loaded locally.
#
# KEEP=1 leaves the container up for poking at.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${SILO_VERSION:-$(cat "$HERE/version")}"
IMG="localhost/deevnet-silo:${VERSION}"
MINIO_IMG="${MINIO_IMG:-quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z}"
NAME=silo-smoke
PORT="${PORT:-19000}"
URL="http://127.0.0.1:${PORT}"
# Scratch for the data directory. NEVER the script's own directory: `make stage`
# refuses a dirty tree, and a smoke run must not be able to stop a release.
WORK="$(mktemp -d -t silo-smoke-XXXXXX)"
ROOT_USER=smokeadmin
ROOT_PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"

pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }
check() { local want="$1" got="$2"; shift 2; if [ "$got" = "$want" ]; then ok "$* ($got)"; else bad "$* (wanted $want, got $got)"; fi; }

cleanup() {
  podman rm -f "$NAME" >/dev/null 2>&1
  # The data directory is written by root inside the container.
  podman unshare rm -rf "$WORK" 2>/dev/null || rm -rf "$WORK"
}
[ -n "${KEEP:-}" ] || trap cleanup EXIT

start() { # image
  podman rm -f "$NAME" >/dev/null 2>&1
  podman run -d --name "$NAME" -p "127.0.0.1:${PORT}:9000" \
    -e MINIO_ROOT_USER="$ROOT_USER" -e MINIO_ROOT_PASSWORD="$ROOT_PASS" \
    -v "$WORK:/data:Z" "$1" server /data >/dev/null || { echo "could not start $1" >&2; exit 2; }
  for _ in $(seq 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/minio/health/live")" = 200 ] && break
    sleep 1
  done
  mc alias set local http://127.0.0.1:9000 "$ROOT_USER" "$ROOT_PASS" >/dev/null || { echo "no admin alias" >&2; exit 2; }
}
mc() { podman exec "$NAME" mc "$@"; }

# A signed S3 request from the host. curl does SigV4 itself (--aws-sigv4), so
# the conditional-write test sends exactly the headers Terraform's SDK does.
s3() { # access secret method path [curl args...]; prints the status code
  local ak="$1" sk="$2" m="$3" p="$4"; shift 4
  curl -s -o /dev/null -w '%{http_code}' --aws-sigv4 "aws:amz:us-east-1:s3" --user "$ak:$sk" \
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" -X "$m" "$@" "$URL$p"
}
anon() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
blob() { head -c "$1" /dev/urandom > "$WORK.blob"; echo "$WORK.blob"; }

policy() { # name json
  printf '%s' "$2" | podman exec -i "$NAME" sh -c "cat > /tmp/$1.json"
  mc admin policy create local "$1" "/tmp/$1.json" >/dev/null
}
user() { # name secret policy
  mc admin user add local "$1" "$2" >/dev/null
  mc admin policy attach local "$3" --user "$1" >/dev/null 2>&1 || true
}

if [ -n "${COMPAT:-}" ]; then
  echo "== COMPAT: MinIO writes, silo reads (CHG-0068 Step 5 rehearsal)"
  podman image exists "$MINIO_IMG" || { echo "  $MINIO_IMG is not loaded" >&2; exit 2; }
  start "$MINIO_IMG"
  mc mb local/tf-state >/dev/null && mc version enable local/tf-state >/dev/null
  policy tenant-old '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::tf-state"],"Condition":{"StringLike":{"s3:prefix":["tenants/old/*"]}}},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::tf-state/tenants/old/*"]}]}'
  user old oldsecret123 tenant-old
  s3 old oldsecret123 PUT /tf-state/tenants/old/terraform.tfstate --data-binary v1 >/dev/null
  s3 old oldsecret123 PUT /tf-state/tenants/old/terraform.tfstate --data-binary v2 >/dev/null
  podman stop "$NAME" >/dev/null
  start "$IMG"
  check 200 "$(s3 old oldsecret123 GET /tf-state/tenants/old/terraform.tfstate)" "MinIO's user reads its state under silo"
  check 2 "$(mc ls --versions local/tf-state/tenants/old/terraform.tfstate | wc -l | tr -d ' ')" "both object versions survive"
  check 403 "$(s3 old oldsecret123 GET /tf-state/tenants/other/terraform.tfstate)" "MinIO's policy still confines it"
  check Enabled "$(mc version info local/tf-state --json | sed -n 's/.*"status":"\([A-Za-z]*\)".*/\1/p')" "versioning still on"
  podman rm -f "$NAME" >/dev/null
  podman unshare rm -rf "$WORK"/* "$WORK"/.minio.sys 2>/dev/null
fi

echo "== $IMG"
start "$IMG"
echo "  $(podman exec "$NAME" silo --version | head -1)"

echo "== 4 versioning"
mc mb local/state >/dev/null && mc version enable local/state >/dev/null
check Enabled "$(mc version info local/state --json | sed -n 's/.*"status":"\([A-Za-z]*\)".*/\1/p')" "versioning on"
mc mb local/plain >/dev/null && mc version enable local/plain >/dev/null && mc version suspend local/plain >/dev/null
check Suspended "$(mc version info local/plain --json | sed -n 's/.*"status":"\([A-Za-z]*\)".*/\1/p')" "versioning switched off again"

echo "== 1 conditional writes on a versioned bucket"
check 200 "$(s3 "$ROOT_USER" "$ROOT_PASS" PUT /state/a.tflock -H 'If-None-Match: *' --data-binary one)" "first If-None-Match: * PUT"
check 412 "$(s3 "$ROOT_USER" "$ROOT_PASS" PUT /state/a.tflock -H 'If-None-Match: *' --data-binary two)" "second If-None-Match: * PUT"
# Atomically: twenty racing writers on a fresh key, exactly one may win.
for i in $(seq 20); do
  { s3 "$ROOT_USER" "$ROOT_PASS" PUT /state/race.tflock -H 'If-None-Match: *' --data-binary "$i"; echo; } > "$WORK.race.$i" &
done; wait
check 1 "$(cat "$WORK".race.* | grep -c 200)" "racing writers that won"
check 19 "$(cat "$WORK".race.* | grep -c 412)" "racing writers refused with 412"
rm -f "$WORK".race.*
s3 "$ROOT_USER" "$ROOT_PASS" DELETE /state/a.tflock >/dev/null
check 200 "$(s3 "$ROOT_USER" "$ROOT_PASS" PUT /state/a.tflock -H 'If-None-Match: *' --data-binary three)" "a released lock (delete marker) can be taken again"

echo "== 2 confinement"
policy prefix-a '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::state"],"Condition":{"StringLike":{"s3:prefix":["tenants/a/*"]}}},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::state/tenants/a/*"]}]}'
user tenant-a secret-a-123 prefix-a
check 200 "$(s3 tenant-a secret-a-123 PUT /state/tenants/a/x --data-binary x)" "prefix key writes its prefix"
check 403 "$(s3 tenant-a secret-a-123 PUT /state/tenants/b/x --data-binary x)" "prefix key refused another prefix"
check 403 "$(s3 tenant-a secret-a-123 GET /plain/x)" "prefix key refused another bucket"
mc mb local/t1-data >/dev/null && mc mb local/t2-data >/dev/null
policy rw-t1 '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::t1-data"]},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::t1-data/*"]}]}'
policy ro-t1 '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::t1-data"]},{"Effect":"Allow","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::t1-data/*"]}]}'
user t1-rw secret-rw-123 rw-t1
user t1-ro secret-ro-123 ro-t1
check 200 "$(s3 t1-rw secret-rw-123 PUT /t1-data/obj --data-binary x)" "bucket key writes its bucket"
check 403 "$(s3 t1-rw secret-rw-123 PUT /t2-data/obj --data-binary x)" "bucket key refused another bucket"
check 200 "$(s3 t1-ro secret-ro-123 GET /t1-data/obj)" "read-only key reads"
check 403 "$(s3 t1-ro secret-ro-123 PUT /t1-data/obj2 --data-binary x)" "read-only key refused a write"
check 403 "$(s3 t1-ro secret-ro-123 DELETE /t1-data/obj)" "read-only key refused a delete"

echo "== 3 quota"
# Silo enforces a bucket quota from its scanner's usage figures
# (cmd/bucket-quota.go: loadDataUsageFromBackend, cached 10 s), so a write past
# the quota is accepted until the scanner has counted the bucket: about a
# minute. Measured 2026-11-14 on this release: 6.2 MB accepted against a 1 MiB
# quota in 63 s. That is why the state store and the bucket store are separate
# instances on separate disks (ADR-0026 §3, CHG-0068). What is checked here is
# what silo does promise: a single-part upload larger than the quota is refused
# at once (a multipart one is not: each part is checked alone, so it is counted
# only after it completes; CHG-0069 saw 1.2 GB land against 1 GiB),
# and once the scanner has counted the bucket every write past it is refused,
# noncurrent versions included.
mc mb local/quota >/dev/null && mc version enable local/quota >/dev/null && mc quota set local/quota --size 1MiB >/dev/null
check 400 "$(s3 "$ROOT_USER" "$ROOT_PASS" PUT /quota/big --data-binary @"$(blob 1100000)")" "an object larger than the quota, at once"
for i in 1 2 3; do s3 "$ROOT_USER" "$ROOT_PASS" PUT /quota/same --data-binary @"$(blob 400000)" >/dev/null; done
echo "  ...  waiting for the scanner to count the bucket (up to ${QUOTA_WAIT:-180} s)"
code=200; t=0
while [ "$code" = 200 ] && [ "$t" -lt "${QUOTA_WAIT:-180}" ]; do
  sleep 10; t=$((t + 10))
  code="$(s3 "$ROOT_USER" "$ROOT_PASS" PUT /quota/probe --data-binary @"$(blob 1000)")"
done
check 400 "$code" "past the quota, counting noncurrent versions, after ${t} s"

echo "== 5 lifecycle"
mc ilm rule add local/quota --expire-days 30 --noncurrent-expire-days 7 >/dev/null
rules="$(mc ilm rule ls local/quota --json)"
case "$rules" in *'"Days":30'*'"NoncurrentDays":7'*|*'"NoncurrentDays":7'*'"Days":30'*) ok "expiry and noncurrent expiry read back";; *) bad "lifecycle rule not as set: $rules";; esac

echo "== 9 anonymous read"
mc mb local/pub >/dev/null
printf 'hello' | podman exec -i "$NAME" mc pipe local/pub/asset.txt >/dev/null
printf 'hello' | podman exec -i "$NAME" mc pipe local/t1-data/private.txt >/dev/null
printf '%s' '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pub/*"]}]}' \
  | podman exec -i "$NAME" sh -c 'cat > /tmp/pub.json'
mc anonymous set-json /tmp/pub.json local/pub >/dev/null
check 200 "$(anon "$URL/pub/asset.txt")" "anonymous GET on the public bucket"
check 403 "$(anon "$URL/pub/")" "anonymous listing of the public bucket refused"
check 403 "$(anon -X PUT --data-binary x "$URL/pub/new.txt")" "anonymous PUT refused"
check 403 "$(anon "$URL/t1-data/private.txt")" "anonymous GET on another bucket refused"

rm -f "$WORK.blob"
echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]

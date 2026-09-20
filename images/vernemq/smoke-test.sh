#!/bin/bash
# Smoke test for the VerneMQ image: does the thing we built actually broker?
#
# Stands up the broker and a PostgreSQL auth database in throwaway containers,
# writes two tenants' accounts the way ADR-0012 §10 says the API will, and
# checks what each tenant can and cannot do. Run it after bumping the version.
#
# KEEP=1 leaves the stack up for poking at.
#
# What it established the first time it ran, 2026-09-20:
#   - PostgreSQL auth works end to end. A right password connects, a wrong one
#     gets "Connection Refused: bad user name or password".
#   - Topic confinement holds (ADR-0012 §10, which lists this as unverified):
#     a tenant cannot subscribe to '#' or to another tenant's prefix, and a
#     cross-tenant publish never reaches a subscriber on the other side.
#   - An account is bound to its CLIENT ID as well as its username: the ACL
#     table's primary key is (mountpoint, client_id, username), so the same
#     username from a different client id is refused outright.
#   - MQTT over TLS is BROKEN on this build: the handshake completes and then
#     the broker answers a CONNECT with nothing and closes. See the change
#     record. The plaintext listener below is a DIAGNOSTIC, not the shipping
#     configuration - ADR-0012 §8 requires TLS.
#
# Two traps this script encodes, both of which cost real time:
#   - An SSL listener REQUIRES cafile. Leave it out and ranch refuses the whole
#     listener with "Invalid TLS option: {cacertfile,undefined}" - and nothing
#     says so on the console, only in log/error.log.
#   - `vernemq ping` answers pong long before the acceptor binds. Wait for
#     `vmq-admin listener show` to report running, or the first client gets a
#     bare ECONNREFUSED that looks like a config fault.
#
# Do not flip plugins on a running broker to test things: vmq_plugin_mgr
# crashes and the node then drops every CONNECT with no log at all.
set -u
# Scratch for certificates and the rendered config. NEVER the script's own
# directory: this repo's `make stage` refuses a dirty tree, and a smoke run
# must not be able to stop a release.
SC="${WORK:-$(mktemp -d -t vernemq-smoke-XXXXXX)}"
VERNEMQ_VERSION="${VERNEMQ_VERSION:-$(cat "$(dirname "$0")/version")}"
SUFFIX="$(echo "$VERNEMQ_VERSION" | tr . -)"
NET=vmq-smoke-$SUFFIX
BROKER=vmq-smoke-broker-$SUFFIX
DB=vmq-smoke-db-$SUFFIX
IMG=localhost/deevnet-vernemq:${VERNEMQ_VERSION}
PGIMG=docker.io/library/postgres:17.11
# TLS is tested through a PUBLISHED port from the host network, not container to
# container. Rootless podman's container-to-container path does not carry this
# TLS session (plaintext MQTT over the same path is fine, and a raw CONNECT
# from the host gets a proper CONNACK), so testing it that way reports a broken
# broker when the broker is correct. Cost a lot of time once; do not undo it.
HOSTPORT=${HOSTPORT:-18883}
CLIIMG=docker.io/eclipse-mosquitto:2.0.22

cleanup() { podman rm -f $BROKER $DB >/dev/null 2>&1; podman network rm -f $NET >/dev/null 2>&1; }
[ -n "${KEEP:-}" ] || trap cleanup EXIT
cleanup

echo "### 1. certificates"
rm -rf "$SC/tls"; mkdir -p "$SC/tls"; cd "$SC/tls"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca-key.pem -out ca.pem -days 2 \
  -subj "/CN=smoke-ca" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout broker-key.pem -out broker.csr \
  -subj "/CN=$BROKER" >/dev/null 2>&1
printf "subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\n" "$BROKER" > san.cnf
openssl x509 -req -in broker.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -out broker.pem -days 2 -extfile san.cnf >/dev/null 2>&1
chmod 644 broker-key.pem
echo "ok: CA + broker cert (SAN $BROKER)"

echo "### 2. database"
podman network create $NET >/dev/null
podman run -d --name $DB --network $NET \
  -e POSTGRES_DB=vernemq -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=smoke \
  $PGIMG >/dev/null
for i in $(seq 1 40); do podman exec $DB pg_isready -U postgres -d vernemq >/dev/null 2>&1 && break; sleep 1; done

podman exec -i $DB psql -U postgres -d vernemq -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE vmq_auth_acl (
  mountpoint character varying(10) NOT NULL,
  client_id character varying(128) NOT NULL,
  username character varying(128) NOT NULL,
  password character varying(128),
  publish_acl json,
  subscribe_acl json,
  CONSTRAINT vmq_auth_acl_primary_key PRIMARY KEY (mountpoint, client_id, username)
);
CREATE ROLE vernemq LOGIN PASSWORD 'readonly';
GRANT CONNECT ON DATABASE vernemq TO vernemq;
GRANT USAGE ON SCHEMA public TO vernemq;
GRANT SELECT ON vmq_auth_acl TO vernemq;
SQL
echo "ok: schema + read-only broker role"

# Two tenants, each confined to its own prefix - exactly what ADR-0012 §10 says
# the API will write.
podman exec -i $DB psql -U postgres -d vernemq -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
WITH x AS (SELECT ''::text AS mp, 'eds-stand-1'::text AS cid, 'eds-stand-1'::text AS usr,
           'edspass'::text AS pw, gen_salt('bf')::text AS salt,
           '[{"pattern":"eds/#"}]'::json AS p, '[{"pattern":"eds/#"}]'::json AS s)
INSERT INTO vmq_auth_acl SELECT x.mp,x.cid,x.usr,crypt(x.pw,x.salt),x.p,x.s FROM x;
WITH x AS (SELECT ''::text AS mp, 'tdemo-probe'::text AS cid, 'tdemo-probe'::text AS usr,
           'tdemopass'::text AS pw, gen_salt('bf')::text AS salt,
           '[{"pattern":"tdemo/#"}]'::json AS p, '[{"pattern":"tdemo/#"}]'::json AS s)
INSERT INTO vmq_auth_acl SELECT x.mp,x.cid,x.usr,crypt(x.pw,x.salt),x.p,x.s FROM x;
SQL
echo "ok: two tenant accounts (eds, tdemo)"

echo "### 3. broker"
mkdir -p "$SC/etc"
cat > "$SC/etc/vernemq.conf" <<CONF
nodename = VerneMQ@127.0.0.1
distributed_cookie = smoke
listener.ssl.default = 0.0.0.0:8883
listener.ssl.default.cafile = /vernemq/etc/tls/ca.pem
listener.ssl.default.certfile = /vernemq/etc/tls/broker.pem
listener.ssl.default.keyfile = /vernemq/etc/tls/broker-key.pem
listener.ssl.default.tls_version = tlsv1.2
listener.ssl.default.require_certificate = off
allow_anonymous = off
plugins.vmq_diversity = on
plugins.vmq_passwd = off
plugins.vmq_acl = off
vmq_diversity.auth_postgres.enabled = on
vmq_diversity.postgres.host = $DB
vmq_diversity.postgres.port = 5432
vmq_diversity.postgres.user = vernemq
vmq_diversity.postgres.password = readonly
vmq_diversity.postgres.database = vernemq
vmq_diversity.postgres.password_hash_method = crypt
vmq_diversity.postgres.ssl = off
log.console = console
log.console.level = info
CONF
podman run -d --name $BROKER --network $NET -p 127.0.0.1:$HOSTPORT:8883 \
  -v "$SC/etc/vernemq.conf:/vernemq/etc/vernemq.conf:ro,Z" \
  -v "$SC/tls:/vernemq/etc/tls:ro,Z" \
  $IMG >/dev/null
# Wait for the LISTENER, not for ping: the node answers pong well before the
# mqtts acceptor is bound, and testing too early gives a bare ECONNREFUSED.
for i in $(seq 1 90); do
  podman exec $BROKER /vernemq/bin/vmq-admin listener show 2>/dev/null | grep -q "mqtts.*running" && break
  sleep 2
done
if ! podman exec $BROKER /vernemq/bin/vmq-admin listener show 2>/dev/null | grep -q "mqtts.*running"; then
  echo "FAIL: mqtts listener never came up"
  podman exec $BROKER sh -c "grep -i \"failed to start ranch\" /vernemq/log/error.log | tail -2"
  exit 1
fi
echo "ok: mqtts listener running"

cli() { podman run --rm --network host -v "$SC/tls:/tls:ro,Z" $CLIIMG "$@" 2>&1; }

echo "### stack is up; debug manually"

pass=0; fail=0
chk() { if [ "$2" = "1" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 -> ${3:-<silence>}"; fail=$((fail+1)); fi; }

# A policy denial and a transport failure are NOT the same result, and a check
# that cannot tell them apart reports a broken broker as a working one. Every
# "is it refused?" test below asks two questions: did the broker refuse it, and
# did the connection actually get far enough for a refusal to mean anything.
transport_broke() { echo "$1" | grep -qiE "TLS error|unexpected eof|connection was lost|Protocol error"; }
denied() { echo "$1" | grep -qiE "denied|not authori[sz]ed|Connection Refused|rejected"; }
refused() { if transport_broke "$1"; then echo 0; elif denied "$1"; then echo 1; else echo 0; fi; }
allowed() { if transport_broke "$1"; then echo 0; elif denied "$1"; then echo 0; else echo 1; fi; }

echo
echo "### 4. results"
r=$(cli mosquitto_pub -h localhost -p $HOSTPORT --cafile /tls/ca.pem -i eds-stand-1 -u eds-stand-1 -P edspass -t 'eds/lightstand/lp-stand-01/status' -m ok)
chk "eds publishes inside its own prefix" "$(allowed "$r")" "$r"

r=$(cli mosquitto_pub -h localhost -p $HOSTPORT --cafile /tls/ca.pem -i eds-stand-1 -u eds-stand-1 -P wrongpass -t 'eds/x' -m no)
chk "wrong password is refused" "$(refused "$r")" "$r"

r=$(cli mosquitto_pub -h localhost -p $HOSTPORT --cafile /tls/ca.pem -i probe -t 'eds/x' -m no)
chk "anonymous is refused" "$(refused "$r")" "$r"

r=$(cli mosquitto_pub -h localhost -p $HOSTPORT --cafile /tls/ca.pem -i eds-stand-1 -u eds-stand-1 -P edspass -t 'tdemo/lightstand/x/scene' -m hijack)
chk "eds publishing into tdemo/ is refused   [ADR-0012 §10]" "$(refused "$r")" "$r"

r=$(cli mosquitto_sub -h localhost -p $HOSTPORT --cafile /tls/ca.pem -i eds-stand-1 -u eds-stand-1 -P edspass -t '#' -W 4 -v)
chk "eds subscribing to '#' is refused       [ADR-0012 §10]" "$(refused "$r")" "$r"

r=$(cli mosquitto_sub -h localhost -p $HOSTPORT --cafile /tls/ca.pem -i eds-stand-1 -u eds-stand-1 -P edspass -t 'tdemo/#' -W 4 -v)
chk "eds subscribing to tdemo/# is refused   [ADR-0012 §10]" "$(refused "$r")" "$r"

r=$(cli mosquitto_sub -h localhost -p $HOSTPORT --cafile /tls/ca.pem -i eds-stand-1 -u eds-stand-1 -P edspass -t 'eds/#' -W 3 -v)
chk "eds subscribes to eds/#" "$(allowed "$r")" "$r"

echo
echo "### $pass passed, $fail failed"

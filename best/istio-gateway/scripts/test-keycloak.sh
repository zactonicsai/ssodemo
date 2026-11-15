#!/usr/bin/env bash
# Check the platform Keycloak from this laptop: realm discovery through the gateway, admin login, realm contents.
#   scripts/test-keycloak.sh [--quiet]
NAMESPACE="${NAMESPACE:-demoweb}"; KC_RELEASE="${KC_RELEASE:-keycloak}"
source "$(dirname "$0")/lib.sh"
need kubectl helm curl python3
Q=0; [ "${1:-}" = "--quiet" ] && Q=1
VALS="$(helm -n "$NAMESPACE" get values "$KC_RELEASE" -a -o json 2>/dev/null)" || die "keycloak release '$KC_RELEASE' not found in $NAMESPACE — run scripts/install-platform.sh"
URL="$(python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["publicUrl"]+d["relativePath"])' <<<"$VALS")"
REALM="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["realm"]["name"])' <<<"$VALS")"
info "Keycloak $URL realm $REALM"
for i in $(seq 1 24); do
  CODE="$(curl -s -m 10 -o /tmp/kc-disc.json -w '%{http_code}' "$URL/realms/$REALM/.well-known/openid-configuration")"
  [ "$CODE" = 200 ] && break; [ "$Q" = 0 ] && echo "    discovery HTTP $CODE, waiting…"; sleep 5
done
[ "$CODE" = 200 ] || die "OIDC discovery not reachable through the gateway (HTTP $CODE): kubectl -n $NAMESPACE get pods,httproute"
ISS="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["issuer"])' </tmp/kc-disc.json)"
[ "$ISS" = "$URL/realms/$REALM" ] && ok "discovery 200, issuer = $ISS" || warn "issuer is $ISS (expected $URL/realms/$REALM) — publicUrl mismatch?"
PASS="$(kubectl -n "$NAMESPACE" get secret keycloak-admin -o jsonpath='{.data.password}' | python3 -c 'import sys,base64;print(base64.b64decode(sys.stdin.read()).decode())')"
TOK="$(curl -s -m 10 -X POST "$URL/realms/master/protocol/openid-connect/token" -d grant_type=password -d client_id=admin-cli -d username=admin --data-urlencode "password=$PASS" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')"
[ -n "$TOK" ] && ok "admin login works (master realm, admin-cli)" || die "admin login failed — Secret keycloak-admin vs bootstrap password mismatch? (kubectl -n $NAMESPACE logs deploy/keycloak)"
curl -s -m 10 -H "Authorization: Bearer $TOK" "$URL/admin/realms/$REALM/groups" | python3 -c 'import sys,json;print("    groups:", [g["name"] for g in json.load(sys.stdin)])'
curl -s -m 10 -H "Authorization: Bearer $TOK" "$URL/admin/realms/$REALM/users" | python3 -c 'import sys,json;print("    users: ", [u["username"] for u in json.load(sys.stdin)])'
curl -s -m 10 -H "Authorization: Bearer $TOK" "$URL/admin/realms/$REALM/clients?clientId=" | python3 -c 'import sys,json;print("    clients:", [c["clientId"] for c in json.load(sys.stdin) if not c["clientId"].startswith(("account","admin-cli","broker","realm-management","security-admin-console"))])'
PG="$(kubectl -n "$NAMESPACE" get pod keycloak-postgres-0 -o jsonpath='{.status.phase}' 2>/dev/null || echo none)"; ok "postgres pod: $PG"
ok "keycloak test passed"

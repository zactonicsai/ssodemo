#!/usr/bin/env bash
# Install the Developer Workspaces portal (web site + API behind oauth2-proxy) on the current kubectl context.
# Requires the platform (gateway + Keycloak) — scripts/install-platform.sh — and checks for it first.
#
#   apps/portal/install.sh [--yes] [--set k=v]...
#
# Environment:
#   NAMESPACE=demoweb  RELEASE=portal  KC_RELEASE=keycloak  APP_PATH=/   VALUES_FILE=   (extra values)
#   SECRETS_FILE=.demoweb/<context>-portal.env  (client secret + cookie secret, kept across upgrades)
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${NAMESPACE:-demoweb}"; RELEASE="${RELEASE:-portal}"; KC_RELEASE="${KC_RELEASE:-keycloak}"; APP_PATH="${APP_PATH:-/}"
source "$APP_DIR/../../scripts/lib.sh"
EXTRA_SET=()
while [ $# -gt 0 ]; do case "$1" in --yes|-y) YES=1 ;; --set) EXTRA_SET+=(--set "$2"); shift ;; -h|--help) sed -n '2,10p' "$0"; exit 0 ;; *) die "unknown flag $1" ;; esac; shift; done
need kubectl helm openssl curl python3
confirm_context
CTX="$(current_context)"; SECRETS_FILE="${SECRETS_FILE:-$ROOT/.demoweb/${CTX}-portal.env}"

# ---- precheck: the platform must be there ----------------------------------------------------------
info "checking the platform in $NAMESPACE"
KCV="$(helm -n "$NAMESPACE" get values "$KC_RELEASE" -a -o json 2>/dev/null)" || die "Keycloak release '$KC_RELEASE' not found in $NAMESPACE.
       Install the platform first:  scripts/install-platform.sh"
kubectl -n "$NAMESPACE" get secret keycloak-admin >/dev/null 2>&1 || die "Secret keycloak-admin missing in $NAMESPACE (keycloak chart not healthy?)"
PUBLIC_URL="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["publicUrl"])' <<<"$KCV")"
KC_PATH="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["relativePath"])' <<<"$KCV")"
REALM="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["realm"]["name"])' <<<"$KCV")"
GATEWAY="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway"])' <<<"$KCV")"
ROUTE="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["routeKind"])' <<<"$KCV")"
HOSTV="$(python3 -c 'import sys,json;print(json.load(sys.stdin).get("hostname",""))' <<<"$KCV")"
KC_IMAGE="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["image"])' <<<"$KCV")"
ok "keycloak release found: $PUBLIC_URL$KC_PATH realm $REALM, gateway $GATEWAY ($ROUTE)"
kubectl -n "$NAMESPACE" rollout status deploy/keycloak --timeout=120s >/dev/null 2>&1 && ok "keycloak deployment ready" || die "keycloak deployment not ready: kubectl -n $NAMESPACE get pods"
CODE="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$PUBLIC_URL$KC_PATH/realms/$REALM/.well-known/openid-configuration")"
[ "$CODE" = 200 ] && ok "realm $REALM answers through the gateway" || warn "realm discovery HTTP $CODE from here (continuing; the in-cluster Job checks again)"

# ---- secrets -----------------------------------------------------------------------------------------
mkdir -p "$(dirname "$SECRETS_FILE")"; touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"; source "$SECRETS_FILE"
[ -n "${CLIENT_SECRET:-}" ] || { CLIENT_SECRET="$(openssl rand -hex 24)"; echo "CLIENT_SECRET=$CLIENT_SECRET" >> "$SECRETS_FILE"; }
[ -n "${COOKIE_SECRET:-}" ] || { COOKIE_SECRET="$(openssl rand -base64 32 | tr -d '\n' | tr -- '+/' '-_')"; echo "COOKIE_SECRET=$COOKIE_SECRET" >> "$SECRETS_FILE"; }
ok "secrets in $SECRETS_FILE"

# ---- install -----------------------------------------------------------------------------------------
info "helm upgrade --install $RELEASE apps/portal/helm/portal"
SET=(--set "publicUrl=$PUBLIC_URL" --set "path=$APP_PATH" --set "hostname=$HOSTV" --set "routeKind=$ROUTE" --set "gateway=$GATEWAY"
     --set "keycloak.publicUrl=$PUBLIC_URL$KC_PATH" --set "keycloak.internalUrl=http://keycloak.$NAMESPACE.svc.cluster.local:8080$KC_PATH"
     --set "keycloak.realm=$REALM" --set "keycloak.image=$KC_IMAGE"
     --set "client.id=$RELEASE" --set "client.secret=$CLIENT_SECRET" --set "oauth2Proxy.cookieSecret=$COOKIE_SECRET"
     --set "oauth2Proxy.cookieSecure=$([[ "$PUBLIC_URL" == https://* ]] && echo true || echo false)")
[ -n "${VALUES_FILE:-}" ] && SET+=(-f "$VALUES_FILE")
SET+=(${EXTRA_SET[@]+"${EXTRA_SET[@]}"})
run helm lint "$APP_DIR/helm/portal" "${SET[@]}" >/dev/null && ok "chart ok"
run helm upgrade --install "$RELEASE" "$APP_DIR/helm/portal" -n "$NAMESPACE" "${SET[@]}" --wait --timeout 8m \
  || warn "helm --wait ended early — continuing with rollout checks"
for d in "$RELEASE-oauth2-proxy" "$RELEASE-web"; do run kubectl -n "$NAMESPACE" rollout status "deploy/$d" --timeout=300s; done
kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$RELEASE-client-register" --timeout=300s >/dev/null 2>&1 \
  && ok "OIDC client '$RELEASE' registered in Keycloak" \
  || { warn "client-register job not complete:"; kubectl -n "$NAMESPACE" logs "job/$RELEASE-client-register" --tail=20 || true; }
echo
info "portal installed"
echo "    open:   ${c_bold}${PUBLIC_URL}${APP_PATH}${c_off}     login: demo / demo123  (or dev2 / dev2pass)"
echo "    test:   apps/portal/test.sh"
echo "    remove: apps/portal/uninstall.sh"

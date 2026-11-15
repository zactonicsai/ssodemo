#!/usr/bin/env bash
# One command: Istio ingress gateway + Keycloak SSO + protected nginx web, all in namespace `demoweb`,
# reachable from any browser on the internet (optionally restricted with --allow-my-ip).
#
#   scripts/deploy-demoweb.sh [--allow-my-ip] [--allow-ip CIDR]... [--yes] [--skip-gateway] [--set k=v]...
#
#   1. scripts/deploy-istio-gateway.sh  (into demoweb; auto-detects the Azure-managed Istio)  — unless --skip-gateway
#   2. waits for the public IP, builds PUBLIC_URL (http://<ip>, or http://<DNS_LABEL>.<region>.cloudapp.azure.com)
#   3. generates/reuses secrets, labels the namespace for sidecar injection
#   4. helm upgrade --install demoweb helm/demoweb-sso
#   5. prints the URL and the demo credentials
#
# Environment:
#   NAMESPACE=demoweb     RELEASE=demoweb       GW_RELEASE=demoweb-gateway
#   DNS_LABEL=            Azure DNS label for the public IP → stable hostname instead of the raw IP (recommended)
#   PUBLIC_URL=           override completely (e.g. https://sso.example.com when you front it with your own DNS/TLS)
#   VALUES_FILE=          extra values for helm/demoweb-sso (users, apps, images, …)
#   SECRETS_FILE=.demoweb/<context>.env   where generated secrets are kept so upgrades don't rotate them
# defaults must be set BEFORE lib.sh (which defaults RELEASE to istio-ingress)
NAMESPACE="${NAMESPACE:-demoweb}"; RELEASE="${RELEASE:-demoweb}"; GW_RELEASE="${GW_RELEASE:-demoweb-gateway}"
source "$(dirname "$0")/lib.sh"

DNS_LABEL="${DNS_LABEL:-}"; PUBLIC_URL="${PUBLIC_URL:-}"
SKIP_GW=0; GW_ARGS=(); EXTRA_SET=()
while [ $# -gt 0 ]; do case "$1" in
  --allow-my-ip|--internal) GW_ARGS+=("$1") ;; --allow-ip) GW_ARGS+=("$1" "$2"); shift ;;
  --skip-gateway) SKIP_GW=1 ;; --yes|-y) YES=1 ;; --set) EXTRA_SET+=(--set "$2"); shift ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;; *) die "unknown flag $1" ;;
esac; shift; done
export YES

need kubectl helm openssl curl python3
confirm_context
CTX="$(current_context)"
SECRETS_FILE="${SECRETS_FILE:-$ROOT/.demoweb/${CTX}.env}"

# ---- 1. gateway in the demoweb namespace ----------------------------------------------------------
if [ "$SKIP_GW" = 0 ]; then
  info "step 1/4 — ingress gateway in $NAMESPACE"
  [ -n "$DNS_LABEL" ] && GW_ARGS+=(--set "azure.dnsLabel=$DNS_LABEL")
  INGRESS_NS="$NAMESPACE" RELEASE="$GW_RELEASE" YES=1 "$ROOT/scripts/deploy-istio-gateway.sh" ${GW_ARGS[@]+"${GW_ARGS[@]}"}
else
  ok "step 1/4 — skipping gateway (assumed present in $NAMESPACE)"
fi
MODE="$(detect_mode)"; export MODE; INGRESS_NS="$NAMESPACE"
if [ "$MODE" = aks-gateway-api ]; then ROUTE=httproute; GWKIND=gateway.gateway.networking.k8s.io; else ROUTE=virtualservice; GWKIND=gateway.networking.istio.io; fi
GW_NAME="$(kubectl -n "$NAMESPACE" get "$GWKIND" -l "app.kubernetes.io/instance=$GW_RELEASE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$GW_NAME" ] || die "no gateway from release $GW_RELEASE found in $NAMESPACE (run without --skip-gateway)"

# ---- 2. public URL --------------------------------------------------------------------------------
info "step 2/4 — public address"
SVC_LINE="$(RELEASE="$GW_RELEASE" gateway_svc)"; read -r SVC_NS SVC_NAME <<<"$SVC_LINE"
IP="$(wait_for_lb_ip "$SVC_NS" "$SVC_NAME")" || die "gateway has no public IP yet"
if [ -z "$PUBLIC_URL" ]; then
  if [ -n "$DNS_LABEL" ]; then
    REGION="$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}')"
    PUBLIC_URL="http://${DNS_LABEL}.${REGION}.cloudapp.azure.com"
  else
    PUBLIC_URL="http://${IP}"
  fi
fi
ok "LB IP $IP → PUBLIC_URL=$PUBLIC_URL"
HOSTNAME_VAL=""; case "$PUBLIC_URL" in http://[0-9]*|https://[0-9]*) ;; *) HOSTNAME_VAL="${PUBLIC_URL#*://}"; HOSTNAME_VAL="${HOSTNAME_VAL%%/*}" ;; esac

# ---- 3. secrets + namespace ------------------------------------------------------------------------
info "step 3/4 — secrets and namespace"
mkdir -p "$(dirname "$SECRETS_FILE")"
if [ -f "$SECRETS_FILE" ]; then source "$SECRETS_FILE"; ok "reusing secrets from $SECRETS_FILE"
else
  OAUTH2_CLIENT_SECRET="$(openssl rand -hex 24)"
  # oauth2-proxy only base64-decodes URL-safe base64 ("-" "_"); standard "+" "/" would be taken as a raw 44-byte string
  OAUTH2_COOKIE_SECRET="$(openssl rand -base64 32 | tr -d '\n' | tr -- '+/' '-_')"
  KC_ADMIN_PASSWORD="$(openssl rand -hex 8)"
  printf 'OAUTH2_CLIENT_SECRET=%s\nOAUTH2_COOKIE_SECRET=%s\nKC_ADMIN_PASSWORD=%s\n' "$OAUTH2_CLIENT_SECRET" "$OAUTH2_COOKIE_SECRET" "$KC_ADMIN_PASSWORD" > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"; ok "generated secrets → $SECRETS_FILE (keep it; delete it to rotate)"
fi
# normalise a cookie secret written by an older version of this script (standard base64 -> URL-safe)
case "$OAUTH2_COOKIE_SECRET" in *+*|*/*)
  OAUTH2_COOKIE_SECRET="$(printf '%s' "$OAUTH2_COOKIE_SECRET" | tr -- '+/' '-_')"
  sed -i.bak "s#^OAUTH2_COOKIE_SECRET=.*#OAUTH2_COOKIE_SECRET=$OAUTH2_COOKIE_SECRET#" "$SECRETS_FILE" && rm -f "$SECRETS_FILE.bak"
  ok "cookie secret converted to URL-safe base64 (oauth2-proxy requirement)" ;;
esac
REV="$(detect_revision "$([ "$MODE" = selfmanaged ] && echo "$ISTIO_NS" || echo aks-istio-system)")"
label_namespace_for_mesh "$NAMESPACE" "$REV" sidecar

# ---- 4. the SSO chart -----------------------------------------------------------------------------
info "step 4/4 — helm upgrade --install $RELEASE helm/demoweb-sso"
SET=(
  --set "publicUrl=$PUBLIC_URL"
  --set "hostname=$HOSTNAME_VAL"
  --set "routeKind=$ROUTE"
  --set "gateway=$NAMESPACE/$GW_NAME"
  --set "oauth2Proxy.clientSecret=$OAUTH2_CLIENT_SECRET"
  --set "oauth2Proxy.cookieSecret=$OAUTH2_COOKIE_SECRET"
  --set "oauth2Proxy.cookieSecure=$([[ "$PUBLIC_URL" == https://* ]] && echo true || echo false)"
  --set "keycloak.admin.password=$KC_ADMIN_PASSWORD"
)
[ -n "$VALUES_FILE" ] && SET+=(-f "$VALUES_FILE")
SET+=(${EXTRA_SET[@]+"${EXTRA_SET[@]}"})
run helm lint "$ROOT/helm/demoweb-sso" ${SET[@]+"${SET[@]}"} >/dev/null && ok "chart ok"
# --wait can abort on a dropped watch ("http2: client connection lost") from a laptop; the release is still applied,
# so don't die here — the explicit rollout waits below are the real check.
run helm upgrade --install "$RELEASE" "$ROOT/helm/demoweb-sso" -n "$NAMESPACE" ${SET[@]+"${SET[@]}"} --wait --timeout 10m \
  || warn "helm --wait ended early (connection drop?) — continuing with rollout checks; status: $(helm -n "$NAMESPACE" status "$RELEASE" -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null || echo unknown)"
for d in keycloak oauth2-proxy web; do run kubectl -n "$NAMESPACE" rollout status "deploy/$d" --timeout=300s; done
kubectl -n "$NAMESPACE" wait --for=condition=complete job/keycloak-post-install --timeout=300s >/dev/null 2>&1 && ok "keycloak post-install job completed (sslRequired=NONE on master + demoweb)" || warn "post-install job not complete yet: kubectl -n $NAMESPACE logs job/keycloak-post-install"
C="$(kubectl -n "$NAMESPACE" get pod -l app=web -o jsonpath='{.items[0].spec.containers[*].name}')"
if kubectl api-resources --api-group=security.istio.io 2>/dev/null | grep -q AuthorizationPolicy; then
  case "$C" in *istio-proxy*) ok "Istio CRDs present and web pods have sidecars ($C): mTLS + AuthorizationPolicy lockdown active" ;;
    *) warn "Istio CRDs present but web pods have NO sidecar ($C): injection webhook missing? lockdown relies on NetworkPolicy" ;; esac
else
  warn "this Istio has no networking/security.istio.io CRDs (Gateway-API-only managed Istio): VirtualService/AuthorizationPolicy skipped;"
  warn "web lockdown is a NetworkPolicy — enforced only if the cluster has a network-policy engine: az aks show -g <rg> -n <name> --query networkProfile.networkPolicy"
fi

# ---- summary --------------------------------------------------------------------------------------
VALS="$(helm -n "$NAMESPACE" get values "$RELEASE" -a -o json)"
DEMO_USER="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["keycloak"]["realm"]["user"]["username"])' <<<"$VALS")"
DEMO_PASS="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["keycloak"]["realm"]["user"]["password"])' <<<"$VALS")"
echo
info "done — open in any browser:"
echo "    ${c_bold}${PUBLIC_URL}/${c_off}                 → redirected to Keycloak login, then the protected nginx page"
echo "    login:  ${c_bold}${DEMO_USER} / ${DEMO_PASS}${c_off}"
echo "    Keycloak admin console: ${PUBLIC_URL}/auth/admin/   (admin / ${KC_ADMIN_PASSWORD})"
echo "    realm:  ${PUBLIC_URL}/auth/realms/demoweb      SAML IdP metadata: ${PUBLIC_URL}/auth/realms/demoweb/protocol/saml/descriptor"
echo
echo "    verify from the terminal:  scripts/test-sso.sh"
echo "    add another service:       edit values 'apps:' (see docs/SSO.md) and re-run this script"

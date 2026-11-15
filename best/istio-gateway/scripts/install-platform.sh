#!/usr/bin/env bash
# Platform = Istio ingress gateway + Keycloak (with PostgreSQL) in namespace demoweb, on the current kubectl context.
# Nothing else. Apps (apps/*/install.sh) are installed afterwards and check that this ran.
#
#   scripts/install-platform.sh [--allow-my-ip] [--allow-ip CIDR]... [--skip-gateway] [--skip-keycloak] [--yes] [--set k=v]...
#
# Environment:
#   NAMESPACE=demoweb  GW_RELEASE=demoweb-gateway  KC_RELEASE=keycloak
#   DNS_LABEL=            Azure DNS label → stable hostname instead of the raw IP (recommended)
#   PUBLIC_URL=           override (e.g. https://sso.example.com behind your own DNS/TLS)
#   KC_VALUES=            extra values file for helm/keycloak (users, groups, postgres size, …)
#   SECRETS_FILE=.demoweb/<context>.env   generated passwords are kept here so upgrades don't rotate them
NAMESPACE="${NAMESPACE:-demoweb}"; GW_RELEASE="${GW_RELEASE:-demoweb-gateway}"; KC_RELEASE="${KC_RELEASE:-keycloak}"
source "$(dirname "$0")/lib.sh"
DNS_LABEL="${DNS_LABEL:-}"; PUBLIC_URL="${PUBLIC_URL:-}"; KC_VALUES="${KC_VALUES:-}"
SKIP_GW=0 SKIP_KC=0; GW_ARGS=(); EXTRA_SET=()
while [ $# -gt 0 ]; do case "$1" in
  --allow-my-ip|--internal) GW_ARGS+=("$1") ;; --allow-ip) GW_ARGS+=("$1" "$2"); shift ;;
  --skip-gateway) SKIP_GW=1 ;; --skip-keycloak) SKIP_KC=1 ;; --yes|-y) YES=1 ;; --set) EXTRA_SET+=(--set "$2"); shift ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;; *) die "unknown flag $1" ;;
esac; shift; done
export YES
need kubectl helm openssl curl python3
confirm_context
CTX="$(current_context)"; SECRETS_FILE="${SECRETS_FILE:-$ROOT/.demoweb/${CTX}.env}"

# ---- 1. gateway -----------------------------------------------------------------------------------
if [ "$SKIP_GW" = 0 ]; then
  info "platform 1/2 — ingress gateway ($GW_RELEASE in $NAMESPACE)"
  [ -n "$DNS_LABEL" ] && GW_ARGS+=(--set "azure.dnsLabel=$DNS_LABEL")
  INGRESS_NS="$NAMESPACE" RELEASE="$GW_RELEASE" YES=1 "$ROOT/scripts/deploy-istio-gateway.sh" ${GW_ARGS[@]+"${GW_ARGS[@]}"}
else ok "platform 1/2 — gateway skipped"; fi
MODE="$(detect_mode)"; export MODE; INGRESS_NS="$NAMESPACE"
if [ "$MODE" = aks-gateway-api ]; then ROUTE=httproute; GWKIND=gateway.gateway.networking.k8s.io; else ROUTE=virtualservice; GWKIND=gateway.networking.istio.io; fi
GW_NAME="$(kubectl -n "$NAMESPACE" get "$GWKIND" -l "app.kubernetes.io/instance=$GW_RELEASE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$GW_NAME" ] || die "no gateway from release $GW_RELEASE in $NAMESPACE (run without --skip-gateway)"
SVC_LINE="$(RELEASE="$GW_RELEASE" gateway_svc)"; read -r SVC_NS SVC_NAME <<<"$SVC_LINE"
IP="$(wait_for_lb_ip "$SVC_NS" "$SVC_NAME")" || die "gateway has no public IP yet"
if [ -z "$PUBLIC_URL" ]; then
  if [ -n "$DNS_LABEL" ]; then REGION="$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}')"; PUBLIC_URL="http://${DNS_LABEL}.${REGION}.cloudapp.azure.com"
  else PUBLIC_URL="http://${IP}"; fi
fi
ok "gateway $GW_NAME → $IP · PUBLIC_URL=$PUBLIC_URL"
HOSTNAME_VAL=""; case "$PUBLIC_URL" in http://[0-9]*|https://[0-9]*) ;; *) HOSTNAME_VAL="${PUBLIC_URL#*://}"; HOSTNAME_VAL="${HOSTNAME_VAL%%/*}" ;; esac
[ "$SKIP_KC" = 1 ] && { ok "platform 2/2 — keycloak skipped"; exit 0; }

# ---- 2. keycloak + postgres -----------------------------------------------------------------------
info "platform 2/2 — Keycloak + PostgreSQL ($KC_RELEASE in $NAMESPACE)"
mkdir -p "$(dirname "$SECRETS_FILE")"; touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"; source "$SECRETS_FILE"
[ -n "${KC_ADMIN_PASSWORD:-}" ] || { KC_ADMIN_PASSWORD="$(openssl rand -hex 10)"; echo "KC_ADMIN_PASSWORD=$KC_ADMIN_PASSWORD" >> "$SECRETS_FILE"; }
[ -n "${KC_PG_PASSWORD:-}" ]    || { KC_PG_PASSWORD="$(openssl rand -hex 16)";    echo "KC_PG_PASSWORD=$KC_PG_PASSWORD" >> "$SECRETS_FILE"; }
ok "secrets in $SECRETS_FILE"
REV="$(detect_revision "$([ "$MODE" = selfmanaged ] && echo "$ISTIO_NS" || echo aks-istio-system)")"
label_namespace_for_mesh "$NAMESPACE" "$REV" sidecar
SET=(--set "publicUrl=$PUBLIC_URL" --set "hostname=$HOSTNAME_VAL" --set "routeKind=$ROUTE" --set "gateway=$NAMESPACE/$GW_NAME"
     --set "admin.password=$KC_ADMIN_PASSWORD" --set "postgres.password=$KC_PG_PASSWORD")
[ -n "$KC_VALUES" ] && SET+=(-f "$KC_VALUES")
SET+=(${EXTRA_SET[@]+"${EXTRA_SET[@]}"})
run helm lint "$ROOT/helm/keycloak" "${SET[@]}" >/dev/null && ok "chart ok"
run helm upgrade --install "$KC_RELEASE" "$ROOT/helm/keycloak" -n "$NAMESPACE" "${SET[@]}" --wait --timeout 12m \
  || warn "helm --wait ended early (connection drop?) — continuing with rollout checks"
run kubectl -n "$NAMESPACE" rollout status statefulset/keycloak-postgres --timeout=300s
run kubectl -n "$NAMESPACE" rollout status deploy/keycloak --timeout=600s
kubectl -n "$NAMESPACE" wait --for=condition=complete job/keycloak-post-install --timeout=300s >/dev/null 2>&1 && ok "post-install job done" || true
"$ROOT/scripts/test-keycloak.sh" --quiet || warn "keycloak smoke test did not pass yet; re-run scripts/test-keycloak.sh in a minute"
echo
info "platform ready"
echo "    Keycloak admin:  ${PUBLIC_URL}/auth/admin/   (admin / ${KC_ADMIN_PASSWORD})"
echo "    realm demoweb:   ${PUBLIC_URL}/auth/realms/demoweb   users: demo/demo123 (developers,admins), dev2/dev2pass (developers)"
echo "    next:            apps/portal/install.sh      (the web site + API; it checks for this Keycloak first)"

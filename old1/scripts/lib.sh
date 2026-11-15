# shellcheck shell=bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- defaults (env overrides) -------------------------------------------------------------------
ISTIO_VERSION="${ISTIO_VERSION:-1.31.1}"
ISTIO_CHART_REPO="${ISTIO_CHART_REPO:-https://istio-release.storage.googleapis.com/charts}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"   # Gateway API CRDs (Istio 1.30+ needs v1.5.x)
ISTIO_NS="${ISTIO_NS:-istio-system}"              # control plane
INGRESS_NS="${INGRESS_NS:-istio-ingress}"         # gateway pods + LB (selfmanaged)
RELEASE="${RELEASE:-istio-ingress}"
VALUES_FILE="${VALUES_FILE:-}"
TEST_NS="${TEST_NS:-nginx-test}"
TEST_RELEASE="${TEST_RELEASE:-nginx-test}"
# AKS add-on mode
AZ_RG="${AZ_RG:-}"; AZ_CLUSTER="${AZ_CLUSTER:-}"
DETECT_REASON=""

c_bold=$'\e[1m'; c_dim=$'\e[2m'; c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_off=$'\e[0m'
info() { echo "${c_bold}==>${c_off} $*"; }
ok()   { echo "${c_ok}  ✓${c_off} $*"; }
warn() { echo "${c_warn}  !${c_off} $*"; }
die()  { echo "${c_err}error:${c_off} $*" >&2; exit 1; }
run()  { echo "${c_dim}  \$ $*${c_off}"; "$@"; }
need() { for b in "$@"; do command -v "$b" >/dev/null 2>&1 || die "'$b' is required but not on PATH"; done; }

current_context() { kubectl config current-context 2>/dev/null || die "no current kubectl context"; }

confirm_context() {
  local ctx server; ctx="$(current_context)"
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  info "kubectl context: ${c_bold}${ctx}${c_off}  ${c_dim}${server}${c_off}"
  case "$server" in *azmk8s.io*) ok "looks like AKS" ;; *) warn "server does not look like AKS (*.azmk8s.io); Azure LB annotations will be ignored elsewhere" ;; esac
  if [ "${YES:-0}" != "1" ] && [ -t 0 ]; then
    read -r -p "    continue on this cluster? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "aborted"
  fi
  kubectl cluster-info >/dev/null 2>&1 || die "cannot reach the cluster"
}

istiod_env() {   # $1 ns  $2 env name
  kubectl -n "$1" get deploy istiod -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$2\")].value}" 2>/dev/null || true
}
# Which Istio is on this cluster?  prints: aks-gateway-api | aks-addon | selfmanaged | none
# (sets DETECT_REASON for the log line)
detect_mode() {
  if kubectl -n aks-istio-system get deploy istiod >/dev/null 2>&1; then
    local gc; gc="$(istiod_env aks-istio-system PILOT_GATEWAY_API_DEFAULT_GATEWAYCLASS_NAME)"
    if [ -n "$gc" ]; then DETECT_REASON="istiod in aks-istio-system with default GatewayClass '$gc'"; echo aks-gateway-api; return; fi
    DETECT_REASON="istiod in aks-istio-system, no Gateway API default class (classic add-on)"; echo aks-addon; return
  fi
  if kubectl -n "$ISTIO_NS" get deploy istiod >/dev/null 2>&1; then DETECT_REASON="istiod in $ISTIO_NS"; echo selfmanaged; return; fi
  DETECT_REASON="no istiod found"; echo none
}
# GatewayClass the managed istiod defaults to (aks-gateway-api)
detect_gatewayclass() { local gc; gc="$(istiod_env aks-istio-system PILOT_GATEWAY_API_DEFAULT_GATEWAYCLASS_NAME)"; echo "${gc:-approuting-istio}"; }

# Make sure the Gateway API CRDs and the managed GatewayClass exist (they are not always pre-installed on AKS).
ensure_gateway_api() {
  if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    ok "Gateway API CRDs present ($(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || echo '?'))"
  else
    info "installing Gateway API CRDs $GATEWAY_API_VERSION (standard channel)"
    run kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
    run kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s
  fi
  local gc ctrl; gc="$(detect_gatewayclass)"; ctrl="$(istiod_env aks-istio-system PILOT_GATEWAY_API_CONTROLLER_NAME)"
  if kubectl get gatewayclass "$gc" >/dev/null 2>&1; then
    ok "GatewayClass $gc exists (controller $(kubectl get gatewayclass "$gc" -o jsonpath='{.spec.controllerName}'))"
  else
    info "creating GatewayClass $gc for controller ${ctrl:-istio.aks.azure.com/gateway-controller}"
    kubectl apply -f - <<EOF2
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: $gc
spec:
  controllerName: ${ctrl:-istio.aks.azure.com/gateway-controller}
  description: Azure-managed Istio ingress (created by scripts/deploy-istio-gateway.sh)
EOF2
  fi
  for _ in $(seq 1 20); do
    [ "$(kubectl get gatewayclass "$gc" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" = True ] && { ok "GatewayClass $gc accepted by istiod"; return 0; }
    sleep 3
  done
  warn "GatewayClass $gc not yet Accepted — istiod may still be reconciling; continuing"
}

# Try to work out the AKS resource group / cluster name for the current context (for az calls).
infer_aks_identity() {
  [ -n "$AZ_RG" ] && [ -n "$AZ_CLUSTER" ] && return 0
  command -v az >/dev/null 2>&1 || return 1
  local fqdn; fqdn="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https://([^:/]+).*#\1#')"
  local line; line="$(az aks list --query "[?fqdn=='$fqdn' || privateFqdn=='$fqdn'].[resourceGroup,name]" -o tsv 2>/dev/null | head -1)"
  [ -n "$line" ] || return 1
  AZ_RG="${AZ_RG:-$(echo "$line" | cut -f1)}"; AZ_CLUSTER="${AZ_CLUSTER:-$(echo "$line" | cut -f2)}"
  ok "AKS cluster: $AZ_CLUSTER in $AZ_RG (from az aks list)"
}
# istiod revision label: "default" or e.g. asm-1-25
detect_revision() {
  local ns="$1"; kubectl -n "$ns" get deploy -l app=istiod -o jsonpath='{.items[0].metadata.labels.istio\.io/rev}' 2>/dev/null || echo default
}
# label a namespace so its pods join the mesh
label_namespace_for_mesh() {   # $1 ns  $2 revision  $3 dataplane (sidecar|ambient)
  if [ "${3:-sidecar}" = ambient ]; then
    run kubectl label ns "$1" istio.io/dataplane-mode=ambient --overwrite
  elif [ "$2" = default ] || [ -z "$2" ]; then
    run kubectl label ns "$1" istio-injection=enabled --overwrite
  else
    run kubectl label ns "$1" "istio.io/rev=$2" --overwrite
  fi
}

# where the gateway Service lives and what it is called
gateway_svc() {
  if [ "${MODE:-selfmanaged}" = "aks-gateway-api" ]; then
    local name; name="$(helm -n "$INGRESS_NS" get values "$RELEASE" -a -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["gatewayAPI"]["name"])' 2>/dev/null || echo default-gateway)"
    local svc; svc="$(kubectl -n "$INGRESS_NS" get svc -l "gateway.networking.k8s.io/gateway-name=$name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    echo "$INGRESS_NS ${svc:-$name-$(detect_gatewayclass)}"
  elif [ "${MODE:-selfmanaged}" = "aks-addon" ]; then
    echo "aks-istio-ingress aks-istio-ingressgateway-$([ "${INTERNAL:-0}" = 1 ] && echo internal || echo external)"
  else
    echo "$INGRESS_NS $(helm -n "$INGRESS_NS" get values "$RELEASE" -a -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway"]["name"])' 2>/dev/null || echo istio-ingressgateway)"
  fi
}

wait_for_lb_ip() {   # $1 ns $2 svc
  local ip=""
  for i in $(seq 1 60); do
    ip="$(kubectl -n "$1" get svc "$2" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    [ "$i" = 1 ] && echo "    waiting for Azure to allocate the load balancer IP…" >&2
    sleep 5
  done
  return 1
}

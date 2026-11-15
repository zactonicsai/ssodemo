#!/usr/bin/env bash
# Deploy an Istio ingress gateway on the CURRENT kubectl context (AKS).
#
#   scripts/deploy-istio-gateway.sh [--mode auto|aks-gateway-api|aks-addon|selfmanaged] [--internal] [--with-test] [--yes] [--set k=v ...]
#
#   --mode auto (default) looks at the cluster:
#     aks-gateway-api  istiod in aks-istio-system with a default GatewayClass (approuting-istio): the Azure-managed
#                      Istio base. Installs a Gateway API Gateway; Istio provisions pods + Azure LB. (No az calls.)
#     aks-addon        classic add-on (aks-istio-ingress, revision asm-x-y): enables the ingress gateway with
#                      `az aks mesh` if needed (AZ_RG, AZ_CLUSTER), installs the Istio Gateway resource only.
#     selfmanaged      no managed Istio found: installs istio-base + istiod with Helm, then the gateway pods + LB.
#   --aks-addon    shorthand for --mode aks-addon
#   --internal     internal (VNet) load balancer instead of a public IP
#   --with-test    afterwards run scripts/test-gateway.sh (deploys nginx and curls through the LB)
#   --set k=v      passed through to helm for the istio-ingress-azure chart (repeatable)
#
# Environment:
#   ISTIO_VERSION=1.31.1  ISTIO_CHART_REPO=…  ISTIO_NS=istio-system  INGRESS_NS=istio-ingress  RELEASE=istio-ingress
#   VALUES_FILE=my-values.yaml          (static IP, DNS label, TLS, hosts … see helm/istio-ingress-azure/values.yaml)
#   AZ_RG / AZ_CLUSTER                  (add-on mode)
#
# Examples:
#   scripts/deploy-istio-gateway.sh --with-test
#   VALUES_FILE=prod.yaml scripts/deploy-istio-gateway.sh --set azure.dnsLabel=myapp-ingress
#   AZ_RG=rg-aks AZ_CLUSTER=aks-prod scripts/deploy-istio-gateway.sh --aks-addon --with-test
source "$(dirname "$0")/lib.sh"

MODE=auto INTERNAL=0 WITH_TEST=0; EXTRA_SET=()
while [ $# -gt 0 ]; do case "$1" in
  --mode) MODE="$2"; shift ;; --aks-addon) MODE=aks-addon ;; --internal) INTERNAL=1 ;; --with-test) WITH_TEST=1 ;; --yes|-y) YES=1 ;;
  --set) EXTRA_SET+=(--set "$2"); shift ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;; *) die "unknown flag $1" ;;
esac; shift; done
export MODE INTERNAL

need kubectl helm python3
confirm_context

if [ "$MODE" = auto ]; then
  DETECTED="$(detect_mode)"; detect_mode >/dev/null   # second call only to fill DETECT_REASON in this shell
  case "$DETECTED" in
    none) MODE=selfmanaged; info "no Istio found → self-managed install" ;;
    *)    MODE="$DETECTED"; info "detected Istio flavour: ${c_bold}${MODE}${c_off}  ${c_dim}(${DETECT_REASON}; override with --mode)${c_off}" ;;
  esac
  export MODE
fi

# ---- 1. control plane ---------------------------------------------------------------------------
if [ "$MODE" = "aks-gateway-api" ]; then
  info "Azure-managed Istio (aks-istio-system)"
  kubectl -n aks-istio-system rollout status deploy/istiod --timeout=120s >/dev/null
  ok "istiod: $(kubectl -n aks-istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}')"
  ensure_gateway_api
  GC="$(detect_gatewayclass)"
  REV="$(detect_revision aks-istio-system)"; ok "revision: $REV"
  SET=(--set mode=aks-gateway-api --set "gatewayAPI.gatewayClassName=$GC" --set "azure.internal=$([ "$INTERNAL" = 1 ] && echo true || echo false)")
elif [ "$MODE" = "aks-addon" ]; then
  info "classic AKS Istio add-on"
  GW_TYPE=$([ "$INTERNAL" = 1 ] && echo internal || echo external)
  if kubectl -n aks-istio-ingress get svc "aks-istio-ingressgateway-$GW_TYPE" >/dev/null 2>&1; then
    ok "$GW_TYPE ingress gateway already enabled (aks-istio-ingress/aks-istio-ingressgateway-$GW_TYPE) — no az calls needed"
  else
    # the add-on's gateway has to be switched on through the AKS API
    need az
    infer_aks_identity || die "the add-on's $GW_TYPE ingress gateway is not enabled and I can't tell which AKS cluster this is.
       Either:  AZ_RG=<rg> AZ_CLUSTER=<name> $0 ...
       or run:  az aks mesh enable-ingress-gateway -g <rg> -n <name> --ingress-gateway-type $GW_TYPE   and re-run."
    if [ "$(az aks show -g "$AZ_RG" -n "$AZ_CLUSTER" --query 'serviceMeshProfile.mode' -o tsv 2>/dev/null)" != "Istio" ]; then
      run az aks mesh enable -g "$AZ_RG" -n "$AZ_CLUSTER"
    fi
    run az aks mesh enable-ingress-gateway -g "$AZ_RG" -n "$AZ_CLUSTER" --ingress-gateway-type "$GW_TYPE"
    run kubectl -n aks-istio-ingress rollout status "deploy/aks-istio-ingressgateway-$GW_TYPE" --timeout=300s
  fi
  REV="$(detect_revision aks-istio-system)"
  ok "add-on revision: $REV"
  SET=(--set mode=aks-addon --set "revision=$REV" --set "azure.internal=$([ "$INTERNAL" = 1 ] && echo true || echo false)")
  INGRESS_NS=aks-istio-ingress
else
  info "Istio control plane ($ISTIO_NS)"
  if kubectl -n "$ISTIO_NS" get deploy istiod >/dev/null 2>&1; then
    ok "istiod already present: $(kubectl -n "$ISTIO_NS" get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}')"
  else
    info "installing Istio $ISTIO_VERSION with Helm"
    run helm repo add istio "$ISTIO_CHART_REPO" --force-update >/dev/null
    run helm repo update istio >/dev/null
    run helm upgrade --install istio-base istio/base -n "$ISTIO_NS" --create-namespace --version "$ISTIO_VERSION" --set defaultRevision=default --wait
    run helm upgrade --install istiod istio/istiod -n "$ISTIO_NS" --version "$ISTIO_VERSION" --wait --timeout 5m
  fi
  run kubectl -n "$ISTIO_NS" rollout status deploy/istiod --timeout=180s
  SET=(--set mode=selfmanaged --set "azure.internal=$([ "$INTERNAL" = 1 ] && echo true || echo false)")
fi

# ---- 2. the gateway chart -----------------------------------------------------------------------
[ -n "$VALUES_FILE" ] && SET+=(-f "$VALUES_FILE")
SET+=("${EXTRA_SET[@]}")
info "helm lint"
run helm lint "$ROOT/helm/istio-ingress-azure" "${SET[@]}" >/dev/null && ok "chart ok"
info "helm upgrade --install $RELEASE -n $INGRESS_NS"
run helm upgrade --install "$RELEASE" "$ROOT/helm/istio-ingress-azure" -n "$INGRESS_NS" --create-namespace "${SET[@]}" --wait --timeout 5m

# ---- 3. wait for the Azure LB -------------------------------------------------------------------
read -r SVC_NS SVC_NAME <<<"$(gateway_svc)"
if [ "$MODE" = aks-gateway-api ]; then
  GWN="$(kubectl -n "$INGRESS_NS" get gateway.gateway.networking.k8s.io -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.name}')"
  info "waiting for Istio to program Gateway $INGRESS_NS/$GWN"
  for i in $(seq 1 36); do
    PROG="$(kubectl -n "$INGRESS_NS" get gateway.gateway.networking.k8s.io "$GWN" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
    [ "$PROG" = True ] && break; sleep 5
  done
  [ "$PROG" = True ] || { kubectl -n "$INGRESS_NS" get gateway.gateway.networking.k8s.io "$GWN" -o yaml | sed -n '/status:/,$p'; die "Gateway not Programmed — see conditions above"; }
  ok "Gateway Programmed"
  read -r SVC_NS SVC_NAME <<<"$(gateway_svc)"     # service exists now
  run kubectl -n "$SVC_NS" rollout status "deploy/$SVC_NAME" --timeout=180s
fi
if [ "$MODE" = selfmanaged ]; then
  run kubectl -n "$SVC_NS" rollout status "deploy/$SVC_NAME" --timeout=180s
  # pods must have been injected (image auto -> real proxy)
  IMG="$(kubectl -n "$SVC_NS" get pods -l "app=$SVC_NAME" -o jsonpath='{.items[0].spec.containers[0].image}')"
  case "$IMG" in auto) die "gateway pod was NOT injected (image still 'auto'). Is istiod running and the revision label right?" ;; *) ok "injected proxy: $IMG" ;; esac
fi
info "load balancer"
IP="$(wait_for_lb_ip "$SVC_NS" "$SVC_NAME")" || die "no LB IP after 5 min: kubectl -n $SVC_NS describe svc $SVC_NAME  (check Azure events / quotas / public IP permissions)"
ok "external IP: ${c_bold}${IP}${c_off}"
DNS="$(kubectl -n "$SVC_NS" get svc "$SVC_NAME" -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/azure-dns-label-name}' 2>/dev/null || true)"
[ -n "$DNS" ] && ok "dns label: $DNS.<region>.cloudapp.azure.com"

info "readiness through the LB (status port)"
STATUS_PORT="$(kubectl -n "$SVC_NS" get svc "$SVC_NAME" -o jsonpath='{.spec.ports[?(@.name=="status-port")].port}')"
if curl -sf -m 5 "http://$IP:${STATUS_PORT:-15021}/healthz/ready" -o /dev/null; then ok "gateway healthy at $IP:${STATUS_PORT:-15021}/healthz/ready"; else warn "status port not reachable from here (fine if the LB is internal or NSG-restricted)"; fi

if [ "$MODE" = aks-gateway-api ]; then
  GW_NS="$INGRESS_NS"; GW_NAME="$GWN"; ATTACH="HTTPRoute parentRefs: [{ name: $GW_NAME, namespace: $GW_NS }]"
else
  GW_NS="$(kubectl get gateway.networking.istio.io -A -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.namespace}')"
  GW_NAME="$(kubectl get gateway.networking.istio.io -A -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.name}')"
  ATTACH="VirtualService gateways: [\"$GW_NS/$GW_NAME\"]"
fi
echo
info "done"
echo "    mode:              $MODE"
echo "    gateway resource:  $GW_NS/$GW_NAME     (attach apps with: $ATTACH)"
echo "    LB service:        $SVC_NS/$SVC_NAME -> $IP"
echo "    test it:           scripts/test-gateway.sh"
[ "$WITH_TEST" = 1 ] && MODE="$MODE" exec "$ROOT/scripts/test-gateway.sh" --gateway "$GW_NS/$GW_NAME"
exit 0

#!/usr/bin/env bash
# Remove the gateway (and optionally Istio itself) from the current context.
#   scripts/undeploy-istio-gateway.sh            removes nginx-test and the istio-ingress release (LB + Gateway)
#   scripts/undeploy-istio-gateway.sh --istio    also uninstalls istiod + istio-base (self-managed only)
#   scripts/undeploy-istio-gateway.sh --aks-addon  disables the add-on ingress gateway + mesh (needs AZ_RG/AZ_CLUSTER)
source "$(dirname "$0")/lib.sh"
need kubectl helm
MODE_FLAG="${1:-}"
confirm_context

"$ROOT/scripts/test-gateway.sh" --cleanup 2>/dev/null || true
if [ "$MODE_FLAG" = "--aks-addon" ]; then
  need az; infer_aks_identity || die "needs AZ_RG and AZ_CLUSTER"
  helm -n aks-istio-ingress uninstall "$RELEASE" 2>/dev/null || true
  run az aks mesh disable-ingress-gateway -g "$AZ_RG" -n "$AZ_CLUSTER" --ingress-gateway-type external || true
  run az aks mesh disable -g "$AZ_RG" -n "$AZ_CLUSTER"
  exit 0
fi
[ "$(detect_mode)" = aks-gateway-api ] && ok "Azure-managed Istio control plane (aks-istio-system) is left alone; only the Gateway release is removed"
info "uninstalling $RELEASE from $INGRESS_NS"
helm -n "$INGRESS_NS" uninstall "$RELEASE" 2>/dev/null && ok "removed (Azure deletes the LB rules / public IP it created)" || warn "release not found"
if [ "$MODE_FLAG" = "--istio" ]; then
  info "uninstalling Istio control plane"
  helm -n "$ISTIO_NS" uninstall istiod 2>/dev/null || true
  helm -n "$ISTIO_NS" uninstall istio-base 2>/dev/null || true
  run kubectl delete ns "$INGRESS_NS" "$ISTIO_NS" --ignore-not-found --wait=false
  warn "Istio CRDs are left in place; remove with: kubectl get crd -oname | grep istio.io | xargs kubectl delete"
fi

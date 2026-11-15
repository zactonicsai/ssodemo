#!/usr/bin/env bash
# Prove the gateway works: deploy helm/nginx-test (with a sidecar), route it through the Gateway, and curl it
# through the Azure load balancer from here.
#
#   scripts/test-gateway.sh [--gateway ns/name] [--host nginx.example.com] [--path /nginx] [--ambient] [--keep] [--cleanup]
#
#   --ambient   join the test namespace to the mesh with ztunnel (istio.io/dataplane-mode=ambient) instead of a sidecar
#   --gateway   Gateway resource to attach to (default: istio-ingress/default-gateway, or aks-istio-ingress/… with MODE=aks-addon)
#   --host      Host header to test with (default "*": any host)
#   --path      path prefix to publish nginx under (default /)
#   --keep      leave nginx-test deployed (default: it is removed when the test passes)
#   --cleanup   only remove nginx-test and exit
source "$(dirname "$0")/lib.sh"
need kubectl helm curl

GW="" HOST="*" PFX="/" KEEP=0 DATAPLANE=sidecar
while [ $# -gt 0 ]; do case "$1" in
  --ambient) DATAPLANE=ambient ;; --gateway) GW="$2"; shift ;; --host) HOST="$2"; shift ;; --path) PFX="$2"; shift ;; --keep) KEEP=1 ;;
  --cleanup) helm -n "$TEST_NS" uninstall "$TEST_RELEASE" 2>/dev/null || true; kubectl delete ns "$TEST_NS" --ignore-not-found; exit 0 ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;; *) die "unknown flag $1" ;;
esac; shift; done

MODE="${MODE:-$(detect_mode)}"; export MODE
[ "$MODE" = none ] && die "no Istio on this cluster — run scripts/deploy-istio-gateway.sh first"
if [ "$MODE" = aks-gateway-api ]; then ROUTE=httproute; GWKIND=gateway.gateway.networking.k8s.io; CP_NS=aks-istio-system
else ROUTE=virtualservice; GWKIND=gateway.networking.istio.io; CP_NS=$([ "$MODE" = aks-addon ] && echo aks-istio-system || echo "$ISTIO_NS"); fi
if [ -z "$GW" ]; then
  GW="$(kubectl get "$GWKIND" -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -m1 'default-gateway' || true)"
  [ -n "$GW" ] || die "no $GWKIND named default-gateway found; pass --gateway ns/name"
fi
INGRESS_NS="${GW%%/*}"
read -r SVC_NS SVC_NAME <<<"$(gateway_svc)"

info "context $(current_context) · mode $MODE · gateway $GW · LB $SVC_NS/$SVC_NAME"
IP="$(wait_for_lb_ip "$SVC_NS" "$SVC_NAME")" || die "gateway service has no external IP yet"
ok "LB IP $IP"

# ---- deploy nginx with a sidecar ----------------------------------------------------------------
info "deploying $TEST_RELEASE into $TEST_NS"
kubectl get ns "$TEST_NS" >/dev/null 2>&1 || run kubectl create ns "$TEST_NS"
REV="$(detect_revision "$CP_NS")"
label_namespace_for_mesh "$TEST_NS" "$REV" "$DATAPLANE"
run helm upgrade --install "$TEST_RELEASE" "$ROOT/helm/nginx-test" -n "$TEST_NS" \
  --set "gateway=$GW" --set "host=$HOST" --set "pathPrefix=$PFX" --set "routeKind=$ROUTE" --wait --timeout 3m
CONTAINERS="$(kubectl -n "$TEST_NS" get pod -l "app=$TEST_RELEASE" -o jsonpath='{.items[0].spec.containers[*].name}')"
if [ "$DATAPLANE" = ambient ]; then ok "ambient namespace (ztunnel); containers: $CONTAINERS"
else case "$CONTAINERS" in *istio-proxy*) ok "nginx pod has the istio-proxy sidecar ($CONTAINERS)" ;; *) warn "no sidecar in nginx pod ($CONTAINERS) — traffic still flows via the gateway, but mTLS won't apply" ;; esac; fi
if [ "$ROUTE" = httproute ]; then
  for i in $(seq 1 12); do
    ACC="$(kubectl -n "$TEST_NS" get httproute "$TEST_RELEASE" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
    [ "$ACC" = True ] && break; sleep 3
  done
  [ "$ACC" = True ] && ok "HTTPRoute accepted by the Gateway" || { warn "HTTPRoute not accepted:"; kubectl -n "$TEST_NS" get httproute "$TEST_RELEASE" -o jsonpath='{.status.parents[0].conditions}'; echo; }
fi

# ---- hit it through the LB ----------------------------------------------------------------------
URL="http://$IP${PFX%/}/"
HDR=(); [ "$HOST" != "*" ] && HDR=(-H "Host: $HOST")
info "GET $URL ${HOST:+(Host: $HOST)}"
PASS=0
for i in $(seq 1 12); do
  OUT="$(curl -s -m 8 -D - ${HDR[@]+"${HDR[@]}"} "$URL" 2>/dev/null || true)"
  CODE="$(printf '%s' "$OUT" | head -1 | awk '{print $2}')"
  if [ "$CODE" = "200" ]; then PASS=1; break; fi
  printf '    attempt %2d: HTTP %s (LB rules / routes still converging)\n' "$i" "${CODE:-no response}"; sleep 5
done
[ "$PASS" = 1 ] || { warn "FAILED. Debug:"; echo "      kubectl -n $SVC_NS logs deploy/$SVC_NAME --tail=50"; echo "      kubectl -n $TEST_NS get httproute,vs,svc,pods"; echo "      kubectl -n ${GW%%/*} get $GWKIND ${GW##*/} -o yaml | sed -n '/status:/,\$p'"; exit 1; }

ok "HTTP 200"
printf '%s' "$OUT" | grep -i '^server:' | sed 's/^/    /' | grep -qi envoy && ok "server: istio-envoy — the request went through the Istio gateway" || warn "no istio-envoy server header"
printf '%s' "$OUT" | grep -i '^x-served-by:' | sed 's/^/    pod: /'
printf '%s' "$OUT" | grep -o '<h1>.*</h1>' | sed 's/<[^>]*>//g;s/^/    body: /'

info "5 requests — should spread across the nginx replicas"
for _ in 1 2 3 4 5; do curl -s -m 8 -D - -o /dev/null ${HDR[@]+"${HDR[@]}"} "$URL" | grep -i '^x-served-by' | tr -d '\r'; done | sort | uniq -c | sed 's/^/    /'

if [ "$KEEP" = 1 ]; then ok "kept: $TEST_NS/$TEST_RELEASE  →  $URL"; else
  info "cleaning up ($TEST_NS)"; helm -n "$TEST_NS" uninstall "$TEST_RELEASE" >/dev/null; kubectl delete ns "$TEST_NS" --wait=false >/dev/null; ok "removed (use --keep to leave it running)"
fi
ok "gateway test passed"

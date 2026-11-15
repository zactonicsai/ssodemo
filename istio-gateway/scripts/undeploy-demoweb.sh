#!/usr/bin/env bash
# Remove the SSO demo (and optionally the gateway) from namespace demoweb on the current context.
#   scripts/undeploy-demoweb.sh            removes keycloak / oauth2-proxy / web / routes / policies
#   scripts/undeploy-demoweb.sh --all      also the gateway release and the namespace
source "$(dirname "$0")/lib.sh"
need kubectl helm
NAMESPACE="${NAMESPACE:-demoweb}"; RELEASE="${RELEASE:-demoweb}"; GW_RELEASE="${GW_RELEASE:-demoweb-gateway}"
confirm_context
info "uninstalling $RELEASE"
helm -n "$NAMESPACE" uninstall "$RELEASE" 2>/dev/null && ok removed || warn "release $RELEASE not found"
if [ "${1:-}" = "--all" ]; then
  info "uninstalling gateway $GW_RELEASE"
  helm -n "$NAMESPACE" uninstall "$GW_RELEASE" 2>/dev/null && ok "removed (Azure releases the LB / public IP)" || warn "release $GW_RELEASE not found"
  run kubectl delete ns "$NAMESPACE" --ignore-not-found --wait=false
fi
ok "done. secrets file kept: $ROOT/.demoweb/$(current_context).env"

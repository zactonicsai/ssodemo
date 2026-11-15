#!/usr/bin/env bash
# Remove the portal (web, API, oauth2-proxy, routes, policies). Its OIDC client is deleted from Keycloak by the
# chart's pre-delete Job. The platform (gateway, Keycloak) is left untouched.
#   apps/portal/uninstall.sh [--yes]
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${NAMESPACE:-demoweb}"; RELEASE="${RELEASE:-portal}"
source "$APP_DIR/../../scripts/lib.sh"
need kubectl helm
[ "${1:-}" = "--yes" ] && YES=1
confirm_context
info "uninstalling $RELEASE from $NAMESPACE"
helm -n "$NAMESPACE" uninstall "$RELEASE" --timeout 5m 2>/dev/null && ok "removed (client '$RELEASE' deleted from Keycloak by the pre-delete job)" || warn "release $RELEASE not found"
kubectl -n "$NAMESPACE" delete job "$RELEASE-client-unregister" --ignore-not-found >/dev/null 2>&1 || true
ok "done — secrets file kept: $ROOT/.demoweb/$(current_context)-portal.env (delete it to rotate on reinstall)"

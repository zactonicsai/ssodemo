#!/usr/bin/env bash
# Remove the platform from the current context.
#   scripts/uninstall-platform.sh            keycloak (DB volume KEPT) — refuses while apps are still installed
#   scripts/uninstall-platform.sh --purge    also delete the Postgres volume (all users/clients gone)
#   scripts/uninstall-platform.sh --all      --purge + gateway + namespace; uninstalls any apps first
NAMESPACE="${NAMESPACE:-demoweb}"; GW_RELEASE="${GW_RELEASE:-demoweb-gateway}"; KC_RELEASE="${KC_RELEASE:-keycloak}"
source "$(dirname "$0")/lib.sh"
need kubectl helm
MODE_FLAG="${1:-}"
confirm_context
APPS="$(helm -n "$NAMESPACE" list -o json 2>/dev/null | python3 -c 'import sys,json;print(" ".join(r["name"] for r in json.load(sys.stdin) if r["name"] not in (sys.argv[1],sys.argv[2])))' "$KC_RELEASE" "$GW_RELEASE")"
if [ -n "$APPS" ]; then
  if [ "$MODE_FLAG" = "--all" ]; then
    for a in $APPS; do info "uninstalling app $a"; run helm -n "$NAMESPACE" uninstall "$a" || true; done
  else die "apps still installed in $NAMESPACE: $APPS — uninstall them first (apps/<name>/uninstall.sh) or use --all"; fi
fi
info "uninstalling $KC_RELEASE"
helm -n "$NAMESPACE" uninstall "$KC_RELEASE" 2>/dev/null && ok "keycloak removed" || warn "release $KC_RELEASE not found"
if [ "$MODE_FLAG" = "--purge" ] || [ "$MODE_FLAG" = "--all" ]; then
  run kubectl -n "$NAMESPACE" delete pvc -l app=keycloak-postgres --ignore-not-found
  run kubectl -n "$NAMESPACE" delete pvc data-keycloak-postgres-0 --ignore-not-found
  ok "postgres volume deleted"
else ok "postgres volume kept (pvc data-keycloak-postgres-0): reinstalling keeps users/clients; --purge to drop it"; fi
if [ "$MODE_FLAG" = "--all" ]; then
  info "uninstalling gateway $GW_RELEASE"
  helm -n "$NAMESPACE" uninstall "$GW_RELEASE" 2>/dev/null && ok "gateway removed (Azure frees the LB / IP)" || warn "release $GW_RELEASE not found"
  run kubectl delete ns "$NAMESPACE" --ignore-not-found --wait=false
fi
ok "done (secrets file kept: $ROOT/.demoweb/$(current_context).env)"

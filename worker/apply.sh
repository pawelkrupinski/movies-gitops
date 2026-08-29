#!/usr/bin/env bash
# Apply one country's worker WITHOUT undoing the image CI pinned.
#
# THE TRAP THIS EXISTS FOR, hit on 2026-08-29. `kubectl apply` and `kubectl set image` fight each
# other: the manifest has to name an image, CI pins a commit SHA with `set image`, and the next
# plain apply writes the manifest's value back -- silently reverting production to `:latest`. Nothing
# errors, the rollout succeeds, and the cluster is now running whatever `latest` points at with no
# record of which build that is.
#
# So the manifest's `image:` is a PLACEHOLDER and this is the only supported way to apply it: read
# the image the Deployment is running, apply, put it back. Structural changes land; the pin survives.
#
#   infra/kubernetes/worker/apply.sh pl                    # keep the running image
#   infra/kubernetes/worker/apply.sh de <full-image-ref>   # apply and move to a specific build
#   infra/kubernetes/worker/apply.sh all                   # every country, each keeping its own pin
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh_target="${KINOWO_K3S_SSH:-root@2.28.52.210}"
kubectl=(ssh -o BatchMode=yes "$ssh_target" -- k3s kubectl)

COUNTRIES=(pl de uk)

usage() { echo "usage: apply.sh <pl|de|uk|all> [image-ref]" >&2; exit 2; }
[[ $# -ge 1 ]] || usage

apply_one() {
  local cc="$1" want="${2:-}"
  [[ -d "$here/overlays/$cc" ]] || { echo "apply.sh: no overlay for '$cc'" >&2; return 2; }

  if [[ -z "$want" ]]; then
    want="$("${kubectl[@]}" -n kinowo get deployment "worker-$cc" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  fi

  # A first-ever apply has no Deployment to read, which is the one case where the placeholder is the
  # right answer -- there is no pinned build to preserve yet.
  if [[ -z "$want" || "$want" == *:latest ]]; then
    echo "==> $cc: no pinned image yet; the manifest value stands"
    want=""
  else
    echo "==> $cc: preserving pinned image ${want##*:}"
  fi

  # RENDERED LOCALLY AND PIPED, rather than copying the tree to the host: the overlays are the
  # source of truth in git, and rendering them where they live means what is applied is what is
  # committed. It also needs no kustomize on the laptop -- `kubectl kustomize` runs on the cluster.
  # A PLAIN ssh, not the kubectl array. `${kubectl[@]/k3s kubectl/}` looks like it would strip the
  # command, but `k3s` and `kubectl` are separate array elements so the pattern never matches -- the
  # result was `kubectl sh -c ...` and the error "unknown command sh for kubectl".
  # NO `sh -c` WRAPPER. ssh already hands the command to a remote shell, so wrapping it adds a
  # second round of quoting that the local shell eats first -- the symptom was `rm: missing operand`,
  # i.e. the arguments had been split apart before they ever reached the host.
  tar -C "$here/.." -cf - worker \
    | ssh -o BatchMode=yes "$ssh_target" \
        "rm -rf /tmp/kw && mkdir -p /tmp/kw && tar -C /tmp/kw -xf -"
  "${kubectl[@]}" apply -k "/tmp/kw/worker/overlays/$cc"

  if [[ -n "$want" ]]; then
    "${kubectl[@]}" -n kinowo set image "deployment/worker-$cc" "worker=$want"
  fi

  "${kubectl[@]}" -n kinowo rollout status "deployment/worker-$cc" --timeout=5m
}

if [[ "$1" == "all" ]]; then
  for cc in "${COUNTRIES[@]}"; do apply_one "$cc" "${2:-}"; done
else
  apply_one "$1" "${2:-}"
fi

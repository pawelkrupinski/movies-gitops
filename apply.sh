#!/usr/bin/env bash
# Apply one tier+country's manifests WITHOUT undoing the image CI pinned.
#
# THE TRAP THIS EXISTS FOR, hit on 2026-08-29. `kubectl apply` and `kubectl set image` fight each
# other: the manifest has to name an image, CI pins a commit SHA with `set image`, and the next
# plain apply writes the manifest's value back -- silently reverting production to `:latest`. Nothing
# errors, the rollout succeeds, and the cluster is now running whatever `latest` points at with no
# record of which build that is.
#
# So every manifest's `image:` is a PLACEHOLDER and this is the only supported way to apply one: read
# the image the Deployment is running, apply, put it back. Structural changes land; the pin survives.
#
# ONE SCRIPT FOR BOTH TIERS. `worker` and `web` are the same shape -- a base plus one overlay per
# country, a Deployment named `<tier>-<cc>` whose container is named `<tier>` -- so the tier is an
# argument rather than a second copy of this file to keep in step.
#
#   infra/kubernetes/apply.sh web pl                     # keep the running image
#   infra/kubernetes/apply.sh worker de <full-image-ref> # apply and move to a specific build
#   infra/kubernetes/apply.sh web all                    # every country, each keeping its own pin
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh_target="${KINOWO_K3S_SSH:-root@128.140.49.167}"
kubectl=(ssh -o BatchMode=yes "$ssh_target" -- k3s kubectl)

COUNTRIES=(pl de uk us es)
TIERS=(worker web)

usage() { echo "usage: apply.sh <worker|web> <pl|de|uk|us|es|all> [image-ref]" >&2; exit 2; }
[[ $# -ge 2 ]] || usage

tier="$1"; shift
# shellcheck disable=SC2076
[[ " ${TIERS[*]} " == *" $tier "* ]] || usage
[[ -d "$here/$tier" ]] || { echo "apply.sh: no manifests for tier '$tier'" >&2; exit 2; }

apply_one() {
  local cc="$1" want="${2:-}"
  [[ -d "$here/$tier/overlays/$cc" ]] || { echo "apply.sh: no overlay for '$tier/$cc'" >&2; return 2; }

  if [[ -z "$want" ]]; then
    want="$("${kubectl[@]}" -n kinowo get deployment "$tier-$cc" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  fi

  # A first-ever apply has no Deployment to read, which is the one case where the placeholder is the
  # right answer -- there is no pinned build to preserve yet.
  if [[ -z "$want" || "$want" == *:latest ]]; then
    echo "==> $tier/$cc: no pinned image yet; the manifest value stands"
    want=""
  else
    echo "==> $tier/$cc: preserving pinned image ${want##*:}"
  fi

  # RENDERED ON THE CLUSTER FROM THE COMMITTED TREE, rather than from whatever kustomize the laptop
  # has: the overlays in git are the source of truth, and `kubectl kustomize` already exists on the
  # host. A PLAIN ssh here, not the kubectl array -- `${kubectl[@]/k3s kubectl/}` looks like it would
  # strip the command, but `k3s` and `kubectl` are separate array elements so the pattern never
  # matches. NO `sh -c` WRAPPER either: ssh already hands the command to a remote shell, and wrapping
  # it adds a second round of quoting the local shell eats first (symptom: `rm: missing operand`).
  tar -C "$here" -cf - "$tier" \
    | ssh -o BatchMode=yes "$ssh_target" \
        "rm -rf /tmp/kw && mkdir -p /tmp/kw && tar -C /tmp/kw -xf -"
  "${kubectl[@]}" apply -k "/tmp/kw/$tier/overlays/$cc"

  if [[ -n "$want" ]]; then
    "${kubectl[@]}" -n kinowo set image "deployment/$tier-$cc" "$tier=$want"
  fi

  "${kubectl[@]}" -n kinowo rollout status "deployment/$tier-$cc" --timeout=5m
}

if [[ "$1" == "all" ]]; then
  for cc in "${COUNTRIES[@]}"; do apply_one "$cc" "${2:-}"; done
else
  apply_one "$1" "${2:-}"
fi

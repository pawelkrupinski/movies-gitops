#!/usr/bin/env bash
# Apply the worker manifests WITHOUT undoing the image CI pinned.
#
# THE TRAP THIS EXISTS FOR, hit on 2026-08-29. `kubectl apply -f deployment.yaml` and
# `kubectl set image` fight each other: the manifest has to name an image, CI pins a commit SHA with
# `set image`, and the next plain `apply` writes the manifest's value back -- silently reverting
# production to `:latest`. Nothing errors, the rollout succeeds, and the cluster is now running
# whatever `latest` happens to point at with no record of which build that is.
#
# So the manifest's `image:` line is a PLACEHOLDER, not a value, and this script is the only
# supported way to apply it: it reads the image the Deployment is currently running, applies the
# manifests, and puts that image straight back. Structural changes land; the pinned build survives.
#
#   infra/kubernetes/worker/apply.sh                    # keep the running image
#   infra/kubernetes/worker/apply.sh <full-image-ref>   # apply and move to a specific build
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh_target="${KINOWO_K3S_SSH:-root@2.28.52.210}"
kubectl=(ssh -o BatchMode=yes "$ssh_target" -- k3s kubectl)

want="${1:-}"

if [[ -z "$want" ]]; then
  want="$("${kubectl[@]}" -n kinowo get deployment worker-pl \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
fi

# A first-ever apply has no Deployment to read, which is the one case where the manifest's
# placeholder is the right answer -- there is no pinned build to preserve yet.
if [[ -z "$want" || "$want" == *:latest ]]; then
  echo "==> no pinned image found (first apply, or currently on :latest); the manifest value stands"
  want=""
else
  echo "==> preserving pinned image: $want"
fi

"${kubectl[@]}" apply -f - < "$here/deployment.yaml"

if [[ -n "$want" ]]; then
  "${kubectl[@]}" -n kinowo set image deployment/worker-pl "worker=$want"
fi

"${kubectl[@]}" -n kinowo rollout status deployment/worker-pl --timeout=5m

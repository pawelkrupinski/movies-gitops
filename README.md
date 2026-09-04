# movies-gitops

The Kubernetes manifests Flux reconciles onto the kinowo k3s cluster. Everything
here is applied continuously; nothing here is applied by hand except the two
bootstrap files called out below.

**The application source lives in [pawelkrupinski/movies](https://github.com/pawelkrupinski/movies).**
This repository holds only what the cluster runs, and it was split out for one
measured reason: Flux pulls its source on every reconcile, and since
image-automation began committing the deployed tag, on the write path of every
deploy too. A shallow clone of the application repository is 93.5 seconds, 228 MB
of `.git` and a 1.3 GB working tree of 18,806 files, to reach 420 KB of manifests
in 36 of them. The same clone here is 2.2 seconds.

## What is where

| path | what it is |
| --- | --- |
| `web/`, `worker/` | the two app tiers: a shared `base/` and one overlay per country |
| `flux/` | Flux's own components and what it watches (`gotk-sync.yaml`) |
| `image-automation/` | the registry scan, the tag policy, and the automation that commits it |
| `flux-metrics/` | metrics Services + the NetworkPolicy that lets Prometheus scrape Flux |
| `headlamp/`, `reloader/`, `kube-state-metrics/` | cluster add-ons |

## How a deploy happens

CI in the application repository builds an image and pushes three tags, one of
which sorts (`main-<utc>-<sha7>`). `image-reflector-controller` sees it,
`image-automation-controller` commits it into `web/base/all.yaml` or
`worker/base/all.yaml`, and `kustomize-controller` applies it.

**The `image:` lines in those two files are written by a machine.** `git log` on
them is the deploy history, and `git revert` is the rollback. Editing one by hand
works and is how you pin, but the automation moves it forward again unless its
`ImageUpdateAutomation` is suspended — and suspending it means a commit here, not
a `kubectl patch`, which the Kustomization reverts within minutes.

## Bootstrap, applied by hand

`flux/gotk-components.yaml` and `flux/gotk-sync.yaml` are NOT reconciled — Flux
does not manage its own controllers here, so a bad component version cannot break
the thing that would roll it back. Changing either means:

```
kubectl apply -f flux/gotk-components.yaml   # controllers + CRDs
kubectl apply -f flux/gotk-sync.yaml         # what Flux watches
```

Everything else reaches the cluster by being merged to `main`.

## Guards live in the application repository

The specs that check these manifests against CI and the nix config are in
`worker/src/test/scala/deploy/` over there, because that is where the other half
of each comparison lives. CI checks this repository out so they can read it.

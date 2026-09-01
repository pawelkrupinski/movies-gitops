# The country workers on k3s

FOUR deployments -- `worker-pl`, `worker-de`, `worker-uk`, `worker-us` -- built from one `base/`
and one overlay each. They run the SAME image and differ in exactly four things: `KINOWO_COUNTRIES`,
the two scrape-rate levers, the JVM heap, and the NodePort. Anything else that differs between them
is a bug in the split, not a feature of a country.

`KINOWO_COUNTRIES` also picks the DATABASE (`Country.mongoDb` derives it), which is why
**`MONGODB_DB` is never set anywhere** -- setting it would pin every country to one database and
merge their corpora.

Every corpus is served: the web tier runs beside these workers on the same cluster (see `../web/`),
one deployment per country. A worker with no readers is no longer a normal state.

`base/` + `overlays/` is the whole deployment. It carries no secrets: two are created out of band and
are the only things standing between a fresh cluster and a running worker.

## The two secrets, and why they are not in git

```
kinowo/worker-secrets      credentials, SHARED by every country (identical: one Mongo user
                           with readWrite on all the databases, one TMDB/OMDb/Zyte key set) (Mongo, TMDB, OMDb, Zyte, Telegram,
                           the Decodo proxy, Sentry)
kinowo/ghcr-pull           a dockerconfigjson for ghcr.io, read:packages ONLY
```

They are applied with `kubectl apply -f -` from a manifest built on the operator's machine out of
the repo-root `.env.local`, piped over SSH rather than passed as arguments — an argv would put every
value into the remote process list for as long as the command ran.

`ghcr-pull` is a **read-only** token on purpose, and specifically NOT the token CI pushes with and
NOT a Fly token. Nothing in this cluster should hold a credential that can deploy to production
somewhere else; that is the same reasoning that keeps `fleet.prometheus.scrapeFly` switched off on
monitoring-1.

## MONGODB_URI points at the private address

```
mongodb://kinowo_app:…@10.20.0.10:27017/kinowo?authSource=kinowo&directConnection=true
```

Not the WireGuard address. This is the entire latency case for moving the worker here: on Fly it
reached mongo-1 through the 6PN tunnel, and here it is one hop across the Hetzner private subnet.
`directConnection=true` because the replica set's member host is that same private address and the
driver must not try to rediscover the topology.

**`MONGODB_DB` is deliberately unset.** `Country.mongoDb` derives the database name from
`KINOWO_COUNTRIES`, so setting it would pin every country to one database.

## Deploying

CI builds `ghcr.io/pawelkrupinski/movies-worker:<sha>` (the `build-worker` job in
`.github/workflows/main.yml`, path-gated on `worker/**` and the shared inputs so a web-only push
never restarts the worker). To roll a build out:

```
# CI does this automatically. By hand, the forced-command endpoint rolls ALL THREE from one
# image reference -- there is no version of "deploy" that leaves two countries on an older build:
ssh -i <k8sdeploy key> k8sdeploy@128.140.49.167 ghcr.io/pawelkrupinski/movies-worker:<sha>

# Structural changes (not just the image) go through the shared apply.sh, which preserves the
# pinned image. It takes the TIER first, because the web deployments use the same script:
infra/kubernetes/apply.sh worker all
```

Always pin the SHA. `latest` exists only so a hand-applied manifest resolves to something; a pod
that restarts under `latest` can come back on a different build with nothing recording which.

## Rolling back to Fly

The Fly app `kinowo-worker` still exists with its secrets and its config. Rollback is
`kubectl -n kinowo scale deployment/worker-pl --replicas=0` (and worker-de / worker-uk) and then starting the Fly machine —
in that order, because two workers would both project the read model and both hold change streams.

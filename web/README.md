# The country web tier on k3s

FOUR deployments — `web-pl`, `web-de`, `web-uk`, `web-us` — built from one `base/` and one overlay
each. They run the SAME image and differ in exactly three things: `KINOWO_COUNTRY`, the CPU request,
and the NodePort. Anything else that differs between them is a bug in the split, not a feature of a
country.

`KINOWO_COUNTRY` is **singular** here. The worker's variable is `KINOWO_COUNTRIES` (plural), and
they are not interchangeable — `Country.soleFromEnv` reads both precisely because getting this wrong
hands the process the Poland default, which on this tier means an English-branded site serving
Polish cinemas. It also selects the database, which is why **`MONGODB_DB` is never set**.

## What makes this tier different from `../worker/`

| | worker | web |
| --- | --- | --- |
| strategy | `Recreate` — two would double-write one corpus | `RollingUpdate`, `maxUnavailable: 0` |
| readiness probe | none; nothing routes to it | required; it is what makes the rolling update honest |
| storage | a 2Gi PVC (heap dumps, logs, AppCDS) | none; stateless |
| public | no | yes — via Caddy on the node, see below |

**One replica each, and that is a monitoring constraint rather than a capacity one.** Prometheus
runs outside the cluster with no Kubernetes credentials, so it scrapes these through the NodePort; a
second replica behind one NodePort would have kube-proxy alternate between two independent sets of
counters, and every alert built on `kinowo_web_movies_served` would see phantom resets. Deploys are
gapless without it — `maxUnavailable: 0` plus the readiness probe means the replacement pod serves
before the old one is terminated.

## How it becomes public

Nothing in the cluster terminates TLS. `k3s` runs with traefik and servicelb disabled, and the
public names are served by **Caddy on the k3s-worker-1 host itself**
(`infra/nix/modules/roles/public-proxy.nix`, configured in `infra/nix/hosts/k3s-worker-1/`), which
reverse-proxies each hostname to a NodePort on loopback:

```
kinowo.net           -> 127.0.0.1:30910   (web-pl)
showtimes.cc/de/*    -> 127.0.0.1:30911   (web-de)
showtimes.cc/uk/*    -> 127.0.0.1:30912   (web-uk)
showtimes.cc/us/*    -> 127.0.0.1:30913   (web-us)
showtimes.cc/        -> 127.0.0.1:30910   the brand front door — a country picker, not Poland's site
www.{kinowo.net,showtimes.cc}             301 to the bare name
```

The Showtimes countries share ONE domain and are told apart by a leading path segment. Each is
still its own pod against its own database — one pod serving four countries would mean one process
against four databases — and each MOUNTS itself at the matching prefix via `play.http.context`,
derived from `models.Country.mountPath`. Caddy does not rewrite paths: the app emits `/uk/…` in
every URL it generates, from reverse routes to the canonical link, the sitemap and the cookie
paths.

The subdomains those countries used to answer on (`uk.`/`de.`/`us.showtimes.cc`) serve NOTHING now
— no vhost, no certificate, no redirect. A redirect map would be a second source of truth for
where each country lives, and the mobile apps are store-release-gated regardless, so the cut is
clean rather than half-migrated. **Installed app builds break until their users update.**

The apex is not a deployment of its own. `models.Country.servesApex` makes a web process render the
country picker when the request `Host` is the bare apex AND that process is mounted at `/` — which
is why the apex falls through to POLAND's pod: it is the only one whose `/` is not already a
country's own landing. The picker renders in English whichever deployment serves it. That fallback
also answers the apex ROOT files a crawler or a mobile OS only ever fetches from a host root —
`/robots.txt`, `/sitemap.xml`, `/.well-known/*` — for which the app has front-door variants (the
sitemap is an INDEX of the three mounted countries, not a list of Poland's cities).

**The A records must exist before a deploy.** Caddy obtains certificates over ACME HTTP-01, so a
name that does not yet resolve to `204.168.140.213` fails issuance and the browser gets a hard TLS
error rather than a degraded page.

## The two secrets, and why they are not in git

```
kinowo/web-secrets    Mongo, TMDB/OMDb, the OAuth client pairs, Sentry, the admin allowlist
kinowo/ghcr-pull      a dockerconfigjson for ghcr.io, read:packages ONLY (shared with the worker)
```

Applied with `kubectl apply -f -` from a manifest built on the operator's machine out of the
repo-root `.env.local`, piped over SSH rather than passed as arguments — an argv would put every
value into the remote process list for as long as the command ran.

## Deploying

CI builds `ghcr.io/pawelkrupinski/movies-web:<sha>` (the `build-web` job in
`.github/workflows/main.yml`) and rolls it through the same forced-command endpoint the worker uses; the endpoint picks the
Deployments from the repository name, so `movies-web` rolls these four and nothing else.

```
# CI does this automatically. By hand:
ssh -i <k8sdeploy key> k8sdeploy@2.28.52.210 ghcr.io/pawelkrupinski/movies-web:<sha>

# Structural changes (not just the image) go through the shared apply.sh, which preserves the
# pinned image CI set:
infra/kubernetes/apply.sh web all
```

Always pin the SHA. `latest` exists only so a hand-applied manifest resolves to something; a pod
that restarts under `latest` can come back on a different build with nothing recording which.

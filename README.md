# AGO deploy

Everything needed to run AGO Platform, and nothing that decides how it behaves.

`docker/` (compose for the fast inner loop - four infrastructure dependencies, no app containers;
the apps run from the IDE against it), `k8s/base/` and `k8s/overlays/local/` (Kustomize for the
Docker Desktop cluster - the same four dependencies plus the three `Ago.Chat.*` host placeholders),
and `seed/` (the MinIO bucket for now; the demo tenant and operator arrive with Stage 1's schema).

Getting started: `../ago-root/docs/runbooks/local-dev.md` (compose loop) and
`../ago-root/docs/runbooks/k8s-local.md` (cluster loop, including the NGINX Gateway Fabric install -
`../ago-root/docs/adr/0014-*`).

Rule that keeps this folder honest: **manifests carry operational concerns only** — TLS, replicas,
limits, probes, coarse rate limits. Business behaviour (per-site CORS, tenant rate limits, auth
decisions) lives in application code, where it is testable and visible to a reviewer.
See `../ago-root/docs/architecture/edge.md` and `../ago-root/docs/runbooks/k8s-local.md`.

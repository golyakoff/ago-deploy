# AGO deploy

Everything needed to run AGO Platform, and nothing that decides how it behaves.

Structure arrives with roadmap Stage 0: `docker/` (compose for the fast inner loop), `k8s/base/`
and `k8s/overlays/local/` (Kustomize for the Docker Desktop cluster), and `seed/` (demo tenant,
operator, MinIO bucket).

Rule that keeps this folder honest: **manifests carry operational concerns only** — TLS, replicas,
limits, probes, coarse rate limits. Business behaviour (per-site CORS, tenant rate limits, auth
decisions) lives in application code, where it is testable and visible to a reviewer.
See `../ago-root/docs/architecture/edge.md` and `../ago-root/docs/runbooks/k8s-local.md`.

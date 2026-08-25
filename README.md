# AGO deploy

Everything needed to run AGO Platform, and nothing that decides how it behaves.

`docker/` (compose for the fast inner loop - four infrastructure dependencies, no app containers;
the apps run from the IDE against it), `k8s/base/` and `k8s/overlays/local/` (Kustomize for the
Docker Desktop cluster - the same four dependencies plus the three `Ago.Chat.*` host placeholders),
and `seed/` (the MinIO bucket, and the demo site + operator - `create-demo-tenant.sh`, idempotent,
Stage 1).

`k8s/backup/` is the odd one out and is deliberately so: **systemd units on the node, not Kubernetes
objects.** Neither `redeploy.sh` nor `kubectl apply -k` reaches it - `install-node.sh` is what installs
it, and has to be re-run after a pull that touches that directory. `../ago-root/docs/runbooks/backup-
and-restore.md` is the procedure, including the restore drill that was actually performed; `../ago-
root/docs/adr/0050-*` is why the scope, the destination and the encryption are what they are.

Getting started: `../ago-root/docs/runbooks/local-dev.md` (compose loop) and
`../ago-root/docs/runbooks/k8s-local.md` (cluster loop, including the NGINX Gateway Fabric install -
`../ago-root/docs/adr/0014-*`).

Rule that keeps this folder honest: **manifests carry operational concerns only** — TLS, replicas,
limits, probes, coarse rate limits. Business behaviour (per-site CORS, tenant rate limits, auth
decisions) lives in application code, where it is testable and visible to a reviewer.
See `../ago-root/docs/architecture/edge.md` and `../ago-root/docs/runbooks/k8s-local.md`.

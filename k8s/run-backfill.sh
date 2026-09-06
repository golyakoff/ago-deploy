#!/usr/bin/env bash
# `22-27`: run `Ago.Chat.RoleAssignmentBackfill` once, on the node.
#
# `22-16` built that host and closed with "the backfill still has to be run on the node" as its
# remainder. That was not the remainder. Running it on 2026-09-04 found three separate reasons it
# could not run at all, none of which any test or CI job could have caught:
#
#   `22-26`  the project was absent from ago-chat's Dockerfile, so the image could not be built
#            (`MSB1009: Project file does not exist` - a message naming neither the project nor the
#            omission)
#   `22-27`  it was absent from build-images.sh, so nothing ever tried to build it
#   `22-27`  it was absent from the postgres-ingress NetworkPolicy, so the pod could not reach the
#            database - the identical failure `8-08`'s migrator hit, on a page that already carried
#            the sentence "adding a workload that talks to Postgres means adding it here"
#
# This script is the fourth thing that was missing: a way to run it that somebody can repeat.
#
# NOT IN THE OVERLAY, DELIBERATELY. The backfill is a one-shot corrective, not a step of every
# deploy. A Job in `overlays/demo` would be recreated and re-run by every `apply-demo.sh` - harmless,
# since the backfill is idempotent by construction, but it would say this is part of deploying, which
# it is not. Applied by hand, when somebody has a reason.
#
# Run on the node:  ~/ago/ago-deploy/k8s/run-backfill.sh
# Environment:
#   NS     namespace (default: ago-chat)
#   TAG    image tag to run (default: whatever ago-chat-api is currently running, so the backfill
#          runs the same commit as the hosts rather than a tag somebody remembered)

set -euo pipefail

NS="${NS:-ago-chat}"
REGISTRY="${REGISTRY:-ghcr.io/golyakoff}"

kc() { if kubectl version >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }

TAG="${TAG:-$(kc get deploy ago-chat-api -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's|.*:||')}"
[ -n "$TAG" ] || { echo "Could not read ago-chat-api's image tag, and none was given." >&2; exit 1; }

# The secret's name carries kustomize's content hash, so it changes whenever the secret does and can
# never be written down here. Read it off the migrator Job, which needs exactly the same credential
# for exactly the same database - and fail loudly rather than guessing a name that would only surface
# as CreateContainerConfigError minutes later.
SECRET="$(kc get job ago-chat-migrator -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].secretRef.name}' 2>/dev/null || true)"
[ -n "$SECRET" ] || { echo "Could not read the credentials secret from ago-chat-migrator in $NS." >&2; exit 1; }

echo "running ${REGISTRY}/ago-chat-roleassignmentbackfill:${TAG} against ${NS}, secret ${SECRET}"

kc delete job ago-chat-roleassignment-backfill -n "$NS" --ignore-not-found >/dev/null

# `app` must be `ago-chat-roleassignment-backfill`: that is the value postgres-ingress admits. Do not
# borrow another workload's label to get through the policy - it would work, and it would make this
# pod answer to `-l app=ago-chat-migrator` for everyone who ever greps for one.
kc apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ago-chat-roleassignment-backfill
  namespace: ${NS}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: ago-chat-roleassignment-backfill
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1654
        runAsGroup: 1654
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: backfill
          image: ${REGISTRY}/ago-chat-roleassignmentbackfill:${TAG}
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          envFrom:
            - secretRef:
                name: ${SECRET}
          env:
            - name: AGO_CHAT_CONNECTION_STRING
              value: "Host=postgres;Port=5432;Database=\$(POSTGRES_DB);Username=\$(POSTGRES_USER);Password=\$(POSTGRES_PASSWORD)"
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              memory: 64Mi
              cpu: 50m
      volumes:
        - name: tmp
          emptyDir: {}
YAML

kc wait --for=condition=complete --timeout=300s job/ago-chat-roleassignment-backfill -n "$NS" \
  || kc wait --for=condition=failed --timeout=10s job/ago-chat-roleassignment-backfill -n "$NS" >/dev/null 2>&1 || true

echo
kc logs job/ago-chat-roleassignment-backfill -n "$NS" 2>&1 | tail -20
echo
echo "  What it says it did is not the check. The check is on the calendar side:"
echo "    kubectl exec -n ${NS} deploy/postgres -c postgres -- \\"
echo "      psql -U ago -d ago_calendar -At -c 'select count(*) from role_assignment_projections'"
echo "  It is idempotent (its own remarks), so re-running it is safe."

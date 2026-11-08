# Kubernetes GitOps Delivery

A small shared-platform delivery lab with Argo CD, Kustomize, a restricted
non-root workload, health checks, a rolling update policy, and a disruption budget.
Personal portfolio project; no employer manifests or production claims.

## Quick start without Argo CD

Requires Docker, kind, and kubectl. This stays on your computer; no AWS account needed.

```bash
kind create cluster --name platform-lab --config kind.yaml
kubectl kustomize k8s/base
kubectl apply -k k8s/base
kubectl -n platform-lab rollout status deploy/platform-web --timeout=120s
kubectl -n platform-lab port-forward service/platform-web 8080:80
# In another terminal:
curl -f http://127.0.0.1:8080/
```

## GitOps flow

Publish this repository first. Install Argo CD in a disposable cluster following
its official getting-started guide. If the repository is private, configure
repository credentials in Argo CD; do not commit them. Confirm the repoURL in
`argocd/application.yaml`, then:

```bash
kubectl apply -f argocd/application.yaml
kubectl -n argocd get application platform-web
```

Submit a PR changing a workload setting, merge it, and observe Argo CD reconcile.
To test drift correction, change a harmless label on the Deployment and observe
self-heal restore Git's definition. To roll back, revert the Git commit and let
Argo CD reconcile. A manual kubectl rollback will be undone by GitOps reconciliation.

## Design and limits

- Two replicas and `maxUnavailable: 0` protect rolling updates if spare capacity exists.
- A PDB limits voluntary evictions; it does not prevent involuntary node failure.
- Topology spreading is a preference for node diversity, not an AZ guarantee.
- ClusterIP avoids external load balancer charges; port-forward is the lab access path.
- nginx uses an unprivileged port, a read-only root filesystem, and writable `/tmp`.
- Image uses a version tag for accessibility; pin a verified digest before promotion.
- The default Argo CD project is for the isolated lab only. Production needs a
  scoped AppProject, explicit destinations, RBAC, repository restrictions, and review gates.
- No HPA or ingress is claimed. Add Metrics Server before implementing CPU autoscaling.

## Evidence and checks

CI renders manifests and runs Kubernetes schema validation. A real kind/EKS
runtime test was not possible in the authoring environment. Save actual rollout,
drift correction, and rollback observations in `docs/experiment.md` when you run it.

## Cleanup

Delete the Argo CD Application before manually deleting its managed workload,
otherwise reconciliation may restore it. Then delete the local cluster:

```bash
kubectl -n argocd delete application platform-web --ignore-not-found
kind delete cluster --name platform-lab
```

## References

- https://argo-cd.readthedocs.io/en/stable/getting_started/
- https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- https://kubernetes.io/docs/concepts/workloads/pods/disruptions/

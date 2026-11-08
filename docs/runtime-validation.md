# Kubernetes and Argo CD runtime evidence

Tested commit: `3445c9b74cd0b269b4de24cb2e47a1bfebcaae08`.

[Successful workflow](https://github.com/hdevops9-ops/kubernetes-gitops-delivery/actions/runs/42449719050) · artifact `gitops-runtime-evidence`.

A real kind cluster ran Argo CD and the workload. Assertions passed for initial rollout/HTTP, replica drift correction from 3 to 2, pod replacement, a failed nonexistent-image promotion, and recovery after restoring source configuration. The failure test uses an Argo CD source override and removal; it does not claim a Git revert occurred. No AWS/EKS cluster, real AZ failure, or zero-downtime SLO was tested.

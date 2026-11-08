#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence
# kind is installed by the workflow. No cloud resources are involved.
kind create cluster --name delivery --image kindest/node:v1.32.2 --config kind.yaml --wait 120s
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.14.2/manifests/install.yaml
kubectl -n argocd wait --for=condition=Ready pods --all --timeout=300s
# Pin the tested commit so results do not silently follow later main changes.
python3 - <<'APP'
import json,os
app={"apiVersion":"argoproj.io/v1alpha1","kind":"Application","metadata":{"name":"platform-web","namespace":"argocd"},"spec":{"project":"default","source":{"repoURL":"https://github.com/"+os.environ['GITHUB_REPOSITORY']+".git","targetRevision":os.environ['GITHUB_SHA'],"path":"k8s/base"},"destination":{"server":"https://kubernetes.default.svc","namespace":"platform-lab"},"syncPolicy":{"automated":{"prune":True,"selfHeal":True},"syncOptions":["CreateNamespace=true"]}}}
open('evidence/test-application.json','w').write(json.dumps(app,indent=2))
APP
# A private repository requires read credentials inside Argo CD. The job token
# is mounted in a temporary Secret; it is never printed or uploaded as evidence.
python3 - <<'AUTH' | kubectl apply -f -
import json,os
print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"ci-repository","namespace":"argocd","labels":{"argocd.argoproj.io/secret-type":"repository"}},"stringData":{"type":"git","url":"https://github.com/"+os.environ['GITHUB_REPOSITORY']+".git","username":"x-access-token","password":os.environ['GH_READ_TOKEN']}}))
AUTH
kubectl apply -f evidence/test-application.json
kubectl -n argocd wait application/platform-web --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s
kubectl -n platform-lab rollout status deployment/platform-web --timeout=180s
kubectl -n platform-lab port-forward service/platform-web 8080:80 > evidence/port-forward.log 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true' EXIT
for attempt in $(seq 1 30); do curl -fsS http://127.0.0.1:8080/ > evidence/initial-response.html && break || sleep 2; done
grep -q 'Welcome to nginx' evidence/initial-response.html
printf 'initial deployment and HTTP: passed
' > evidence/results.txt
# Apply drift; controller must restore the Git replica count (two).
kubectl -n platform-lab scale deployment/platform-web --replicas=3
for attempt in $(seq 1 60); do
  replicas=$(kubectl -n platform-lab get deployment/platform-web -o jsonpath='{.spec.replicas}')
  [[ "$replicas" == 2 ]] && break
  sleep 2
done
[[ "$replicas" == 2 ]]
printf 'Argo CD replica drift correction: passed
' >> evidence/results.txt
# Delete a running Pod, then prove controller replacement and workload readiness.
victim=$(kubectl -n platform-lab get pod -l app=platform-web -o jsonpath='{.items[0].metadata.name}')
kubectl -n platform-lab delete pod "$victim" --wait=true
kubectl -n platform-lab rollout status deployment/platform-web --timeout=120s
kubectl -n platform-lab wait --for=condition=Ready pods -l app=platform-web --timeout=120s
printf 'Pod failure and replacement: passed
' >> evidence/results.txt
# Failed promotion: application source override deliberately references a nonexistent image.
kubectl -n argocd patch application/platform-web --type=merge -p '{"spec":{"source":{"kustomize":{"images":["nginxinc/nginx-unprivileged=nginxinc/nginx-unprivileged:missing-ci-image"]}}}}'
for attempt in $(seq 1 90); do
  image=$(kubectl -n platform-lab get deployment/platform-web -o jsonpath='{.spec.template.spec.containers[0].image}')
  [[ "$image" == *missing-ci-image ]] && break
  sleep 2
done
[[ "$image" == *missing-ci-image ]]
if kubectl -n platform-lab rollout status deployment/platform-web --timeout=45s; then
  echo 'Expected bad-image rollout to fail' >&2; exit 1
fi
kubectl -n platform-lab get pods -o wide > evidence/failed-promotion-pods.txt
printf 'bad-image promotion failure detected: passed
' >> evidence/results.txt
# Restore desired source configuration. This tests recovery, not a fabricated Git revert.
kubectl -n argocd patch application/platform-web --type=merge -p '{"spec":{"source":{"kustomize":null}}}'
for attempt in $(seq 1 90); do
  image=$(kubectl -n platform-lab get deployment/platform-web -o jsonpath='{.spec.template.spec.containers[0].image}')
  [[ "$image" == nginxinc/nginx-unprivileged:1.28-alpine ]] && break
  sleep 2
done
[[ "$image" == nginxinc/nginx-unprivileged:1.28-alpine ]]
kubectl -n platform-lab rollout status deployment/platform-web --timeout=180s
kill "$forward_pid" 2>/dev/null || true
kubectl -n platform-lab port-forward service/platform-web 8080:80 > evidence/recovery-port-forward.log 2>&1 &
forward_pid=$!
for attempt in $(seq 1 30); do curl -fsS http://127.0.0.1:8080/ > evidence/recovered-response.html && break || sleep 2; done
grep -q 'Welcome to nginx' evidence/recovered-response.html
printf 'restore source and HTTP recovery: passed
' >> evidence/results.txt
kubectl -n platform-lab get deployment,pods,pdb,service -o wide > evidence/final-workloads.txt
kubectl -n argocd get application platform-web -o json > evidence/application-final.json
cat evidence/results.txt

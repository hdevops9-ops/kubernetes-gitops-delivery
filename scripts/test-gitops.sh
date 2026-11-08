#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence
work="$RUNNER_TEMP/gitops-source"
repos="$RUNNER_TEMP/gitops-repos"
mkdir -p "$repos"
git clone --no-hardlinks "$GITHUB_WORKSPACE" "$work"
git -C "$work" checkout -B integration-promotion "$GITHUB_SHA"
git -C "$work" config user.name 'CI integration harness'
git -C "$work" config user.email 'ci-integration@example.invalid'
docker load -i evidence/image.tar
# This registry is reachable only on loopback and the disposable kind network.
docker run -d --name delivery-registry -p 127.0.0.1:5001:5000 registry:2
cat > "$RUNNER_TEMP/helm-kind.yaml" <<'KIND'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
nodes:
- role: control-plane
- role: worker
- role: worker
KIND
kind create cluster --name helm-delivery --image kindest/node:v1.32.2 --config "$RUNNER_TEMP/helm-kind.yaml" --wait 120s
docker network connect kind delivery-registry
for node in $(kind get nodes --name helm-delivery); do
  docker exec "$node" mkdir -p /etc/containerd/certs.d/localhost:5001
  printf '[host."http://delivery-registry:5000"]\n  capabilities = ["pull", "resolve"]\n' | docker exec -i "$node" tee /etc/containerd/certs.d/localhost:5001/hosts.toml >/dev/null
done
docker tag platform-api:ci localhost:5001/platform-api:ci
docker push localhost:5001/platform-api:ci | tee evidence/local-image-push.txt
digest=$(curl -fsSI -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' http://127.0.0.1:5001/v2/platform-api/manifests/ci | awk 'tolower($1)=="docker-content-digest:" {gsub("\r", "", $2); print $2}')
[[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
(cd "$work" && python3 scripts/promote.py dev localhost:5001/platform-api "$digest" ci-v1)
git -C "$work" add environments/dev/values.yaml
git -C "$work" commit -m 'Test: promote initial verified image digest'
git clone --bare "$work" "$repos/source.git"
# Serve the test repository read-only over the isolated Docker network. The Git
# commits below are test fixtures, never pushed to the user's GitHub history.
mkdir -p "$RUNNER_TEMP/git-daemon"
printf 'FROM alpine:3.21\nRUN apk add --no-cache git git-daemon\nENTRYPOINT ["git","daemon","--verbose","--export-all","--base-path=/repos","--listen=0.0.0.0","--port=9418","--reuseaddr","/repos"]\n' > "$RUNNER_TEMP/git-daemon/Dockerfile"
docker build -t delivery-git-server "$RUNNER_TEMP/git-daemon"
docker run -d --name delivery-git --network kind -v "$repos:/repos:ro" delivery-git-server
git_ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' delivery-git)
export TEST_GIT_URL="git://$git_ip/source.git"
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml
kubectl -n argocd wait --for=condition=Ready pods --all --timeout=300s
kubectl apply -f gitops/bootstrap/namespaces.yaml
kubectl apply -f gitops/bootstrap/image-policy.yaml
# Prove admission rejects mutable image tags, using server-side dry-run only.
blocked=false
for attempt in $(seq 1 30); do
  if kubectl -n platform-dev create deployment policy-negative-check --image=nginx:latest --dry-run=client -o yaml | kubectl -n platform-dev apply --dry-run=server -f - > evidence/admission-negative-test.txt 2>&1; then
    sleep 2
  else
    if grep -q 'immutable SHA256 image digests' evidence/admission-negative-test.txt; then blocked=true;break;fi
    cat evidence/admission-negative-test.txt;exit 1
  fi
done
[[ "$blocked" == true ]]
python3 - <<'BOOTSTRAP'
import os,yaml,json,subprocess
project=yaml.safe_load(open('gitops/projects/dev.yaml'));project['spec']['sourceRepos']=[os.environ['TEST_GIT_URL']]
app=yaml.safe_load(open('gitops/applications/dev.yaml'));app['spec']['source']['repoURL']=os.environ['TEST_GIT_URL'];app['spec']['source']['targetRevision']='integration-promotion'
for obj in (project,app):subprocess.run(['kubectl','apply','-f','-'],input=json.dumps(obj),text=True,check=True)
BOOTSTRAP
wait_sync() {
  local revision="$1"
  for attempt in $(seq 1 150); do
    kubectl -n argocd annotate application platform-api-dev argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    snapshot=$(kubectl -n argocd get application platform-api-dev -o json)
    if printf '%s' "$snapshot" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("status",{});sys.exit(not (d.get("sync",{}).get("revision")==sys.argv[1] and d.get("sync",{}).get("status")=="Synced" and d.get("health",{}).get("status")=="Healthy"))' "$revision"; then return; fi
    sleep 3
  done
  kubectl -n argocd get application platform-api-dev -o yaml; return 1
}
forward_pid=''
forward() {
  [[ -z "$forward_pid" ]] || kill "$forward_pid" 2>/dev/null || true
  kubectl -n platform-dev port-forward service/platform-api 8080:80 > evidence/port-forward.log 2>&1 &
  forward_pid=$!
  for attempt in $(seq 1 30); do curl -fsS http://127.0.0.1:8080/healthz >/dev/null && return || sleep 2; done
  return 1
}
check_version() {
  curl -fsS http://127.0.0.1:8080/ | python3 -c 'import json,sys; d=json.load(sys.stdin);assert d["version"]==sys.argv[1],d' "$1"
}
trap '[[ -z "$forward_pid" ]] || kill "$forward_pid" 2>/dev/null || true' EXIT
wait_sync "$(git -C "$work" rev-parse HEAD)"
forward;check_version ci-v1
printf 'admission rejected mutable image: passed\n' > evidence/admission-results.txt
printf 'digest-pinned image deployed through Helm and Argo CD: passed\n' > evidence/helm-gitops-results.txt
kubectl -n platform-dev scale deploy/platform-api --replicas=3
for attempt in $(seq 1 60); do
  replicas=$(kubectl -n platform-dev get deploy/platform-api -o jsonpath='{.spec.replicas}')
  [[ "$replicas" == 2 ]] && break
  sleep 2
done
[[ "$replicas" == 2 ]]
printf 'replica drift self-healed: passed\n' >> evidence/helm-gitops-results.txt
# Real Git promotion in the isolated test remote.
(cd "$work" && python3 scripts/promote.py dev localhost:5001/platform-api "$digest" ci-v2)
git -C "$work" add environments/dev/values.yaml;git -C "$work" commit -m 'Test: promote release configuration v2'
git -C "$work" push "$repos/source.git" integration-promotion
wait_sync "$(git -C "$work" rev-parse HEAD)"
forward;check_version ci-v2
printf 'Git commit promotion reconciled to v2: passed\n' >> evidence/helm-gitops-results.txt
# Promote a valid-format nonexistent digest; rollout must fail while old replicas remain.
(cd "$work" && python3 scripts/promote.py dev localhost:5001/platform-api "sha256:$(printf 'f%.0s' {1..64})" bad-release)
git -C "$work" add environments/dev/values.yaml;git -C "$work" commit -m 'Test: failed image promotion'
bad=$(git -C "$work" rev-parse HEAD)
git -C "$work" push "$repos/source.git" integration-promotion
for attempt in $(seq 1 90); do
  kubectl -n argocd annotate application platform-api-dev argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  image=$(kubectl -n platform-dev get deploy/platform-api -o jsonpath='{.spec.template.spec.containers[0].image}')
  [[ "$image" == *ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff ]] && break
  sleep 2
done
[[ "$image" == *ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff ]]
if kubectl -n platform-dev rollout status deploy/platform-api --timeout=45s;then echo 'Expected failed image rollout' >&2;exit 1;fi
forward;check_version ci-v2
printf 'bad digest rollout failed and prior version remained reachable: passed\n' >> evidence/helm-gitops-results.txt
git -C "$work" revert --no-edit "$bad"
git -C "$work" push "$repos/source.git" integration-promotion
wait_sync "$(git -C "$work" rev-parse HEAD)"
forward;check_version ci-v2
printf 'Git revert restored healthy desired state: passed\n' >> evidence/helm-gitops-results.txt
kubectl -n platform-dev get deployment,pods,pdb,service,networkpolicy -o wide > evidence/helm-workloads.txt
git -C "$work" log -4 --format='%H %s' > evidence/test-git-history.txt
kubectl -n argocd get application platform-api-dev -o json > evidence/helm-application.json
cat evidence/helm-gitops-results.txt

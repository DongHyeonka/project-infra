# Project-Infra 운영 가이드

개발한 앱을 Docker 이미지로 빌드하고, 클러스터 내 Private Registry에 Push하고, Kubernetes에 배포하기까지의 전체 과정을 다룬다.

---

## 목차

1. [인프라 최초 셋업](#1-인프라-최초-셋업)
2. [Vault 시크릿 관리](#2-vault-시크릿-관리)
3. [Docker Registry 사용법](#3-docker-registry-사용법)
4. [앱을 Kubernetes에 배포하기](#4-앱을-kubernetes에-배포하기)
5. [시크릿을 앱에서 사용하기](#5-시크릿을-앱에서-사용하기)
6. [환경별 배포](#6-환경별-배포)
7. [트러블슈팅](#7-트러블슈팅)

---

## 1. 인프라 최초 셋업

아래 순서대로 한 번만 실행하면 된다. `k8s/scripts/env/bootstrap.sh`를 사용하면 interactive 단계(`seed-registry.sh`)를 포함한 전 과정을 순서대로 진행한다.

### 자동 셋업 (권장)

```bash
k8s/scripts/env/bootstrap.sh dev
```

스크립트가 다음을 순서대로 실행한다:

1. `kubectl apply -k` — 인프라 리소스 배포
2. Vault Pod Ready 대기
3. `scripts/vault/init.sh` — Vault 초기화 + unseal + auth 설정
4. `scripts/vault/seed-registry.sh` — Docker Registry 시크릿 저장 (**비밀번호 입력 필요**)
5. `install.sh` — VSO Helm 설치
6. VSO Pod Ready 대기
7. `kubectl apply -k` — VSO 리소스 배포
8. Secret 생성 및 전체 Pod 상태 확인

### 수동 셋업

자동 셋업이 안 되거나, 단계별로 확인하면서 진행하고 싶으면 아래를 따른다.

### 1-1. 인프라 리소스 배포

```bash
# dev 환경 기준
kubectl apply -k k8s/overlays/dev/managing/
```

이 명령으로 `mnt` 네임스페이스에 다음이 생성된다:
- Vault StatefulSet + Service + ServiceAccount + ClusterRoleBinding
- Docker Registry Deployment + Service (Secret이 없어 Pod는 아직 ContainerCreating)

`VaultAuth`, `VaultConnection`, `VaultStaticSecret` 리소스는 VSO Helm 설치 후 별도로 적용한다.

> **주의**: Docker Registry Pod는 `docker-registry-htpasswd` Secret이 volume mount로 필요하다. VSO가 이 Secret을 만들기 전까지 ContainerCreating 상태가 정상이다.

### 1-2. Vault 초기화

Vault Pod가 Running 상태가 될 때까지 기다린 후 실행한다.

```bash
# Vault Pod 대기
kubectl wait --for=condition=Ready pod/vault-0 -n mnt --timeout=120s

# 초기화 스크립트 실행
k8s/scripts/vault/init.sh
```

스크립트가 완료되면:
- `vault-init-keys.json` 파일에 Unseal Key 5개 + Root Token이 저장된다
- **이 파일을 안전한 곳에 백업할 것** (git에 커밋하면 안 됨)
- KV v2 엔진, Kubernetes Auth, VSO Policy/Role이 모두 설정된다

**Kubernetes Auth 설정 상세:**

`k8s/scripts/vault/init.sh`는 Kubernetes Auth 활성화 시 다음을 자동으로 설정한다:
- `kubernetes_ca_cert` — Vault Pod의 SA CA 인증서 (`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`)
- `token_reviewer_jwt` — Vault Pod의 SA 토큰 (`/var/run/secrets/kubernetes.io/serviceaccount/token`)

이 두 값이 없으면 VSO가 Vault에 로그인할 때 `403 permission denied`가 발생한다. 또한 Vault SA에 `system:auth-delegator` ClusterRoleBinding이 있어야 TokenReview API 호출이 가능하다 (이 바인딩은 `clusterrolebinding.yaml`로 1-1 단계에서 이미 배포됨).

### 1-3. Docker Registry 시크릿 저장

```bash
k8s/scripts/vault/seed-registry.sh
```

- push-user, pull-user 비밀번호를 입력하면 htpasswd 생성 + Vault 저장까지 자동으로 처리된다
- Vault UI(`http://<노드IP>:30820/ui`)에서 `secret/docker-registry/` 경로에 저장된 것을 확인할 수 있다

### 1-4. VSO Helm 설치

```bash
k8s/vso/helm/vault-secrets-operator/install.sh
```

설치 후 VSO Pod가 Ready 될 때까지 기다린다:

```bash
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault-secrets-operator -n mnt --timeout=120s
```

### 1-5. VSO 리소스 배포

VSO CRD가 준비되면 아래 리소스를 적용한다:

```bash
kubectl apply -k k8s/overlays/dev/managing/vault-secrets-operator/
```

적용 후 VSO가 Vault에서 시크릿을 읽어 K8s Secret을 자동 생성한다:
- `docker-registry-htpasswd` — Registry 인증용
- `registry-pull-credential` — 이미지 Pull용

### 1-6. 확인

```bash
# Secret이 생성되었는지 확인
kubectl get secrets -n mnt
# docker-registry-htpasswd, registry-pull-credential 이 있으면 성공

# 전체 Pod 상태 확인
kubectl get pods -n mnt
# vault-0: Running
# docker-registry-xxx: Running
# vault-secrets-operator-xxx: Running
```

---

## 2. Vault 시크릿 관리

### Vault UI 접근

```
http://<노드IP>:30820/ui
```

Root Token으로 로그인한다 (`vault-init-keys.json`에서 확인).

### UI에서 시크릿 추가/수정

1. 좌측 메뉴 **Secrets Engines** > `secret/` 클릭
2. **Create secret** 클릭
3. Path에 경로 입력 (예: `my-app/config`)
4. Key-Value 쌍 입력 후 **Save**

### CLI에서 시크릿 추가/수정

```bash
# Vault Pod 접속
kubectl exec -it vault-0 -n mnt -- /bin/sh

# 로그인
vault login <root-token>

# 시크릿 저장
vault kv put secret/my-app/config \
  DB_HOST="db.mnt.svc.cluster.local" \
  DB_PASSWORD="my-secure-password" \
  API_KEY="ak-xxxxxxxxxxxx"

# 시크릿 조회
vault kv get secret/my-app/config

# 시크릿 특정 키만 조회
vault kv get -field=DB_PASSWORD secret/my-app/config

# 시크릿 삭제
vault kv delete secret/my-app/config
```

### 앱용 Vault Policy 추가

새 앱의 시크릿을 VSO가 읽을 수 있도록 Policy를 업데이트한다.

**방법 1: Vault UI**

1. `http://<노드IP>:30820/ui` 접속, Root Token으로 로그인
2. 상단 메뉴 **Policies** 클릭
3. `vault-secrets-operator` Policy 클릭 → **Edit policy**
4. 새 앱 경로를 추가:
```hcl
path "secret/data/docker-registry/*" {
  capabilities = ["read"]
}
path "secret/data/my-app/*" {
  capabilities = ["read"]
}
```
5. **Save** 클릭

**방법 2: CLI**

```bash
kubectl exec -it vault-0 -n mnt -- /bin/sh

vault login <root-token>

vault policy write vault-secrets-operator - <<EOF
path "secret/data/docker-registry/*" {
  capabilities = ["read"]
}
path "secret/data/my-app/*" {
  capabilities = ["read"]
}
EOF
```

> Policy 생성/수정은 UI에서 가능하지만, Kubernetes Auth Role 바인딩(`vault write auth/kubernetes/role/...`)은 CLI로만 가능하다. 최초 셋업 시 `k8s/scripts/vault/init.sh`가 Role을 자동 생성하므로 이후에는 Policy만 수정하면 된다.

---

## 3. Docker Registry 사용법

### Registry 접근 정보

| 항목 | 값 |
|------|---|
| 클러스터 내부 주소 | `docker-registry.mnt.svc.cluster.local:5000` |
| 인증 | htpasswd (push-user / pull-user) |

### 클러스터 외부에서 Registry 접근

클러스터 외부(개발 머신)에서 push하려면 port-forward를 사용한다:

```bash
# 터미널 1: port-forward 유지
kubectl port-forward -n mnt svc/docker-registry 5000:5000
```

### 이미지 Push

```bash
# 1. 앱 이미지 빌드
cd /path/to/my-app
docker build -t my-app:v1.0.0 .

# 2. Registry 주소로 태깅
# 클러스터 외부 (port-forward 사용 시)
docker tag my-app:v1.0.0 localhost:5000/my-app:v1.0.0

# 클러스터 내부 (CI/CD 등)
docker tag my-app:v1.0.0 docker-registry.mnt.svc.cluster.local:5000/my-app:v1.0.0

# 3. 로그인
docker login localhost:5000
# Username: push-user
# Password: (`seed-registry.sh`에서 입력한 비밀번호)

# 4. Push
docker push localhost:5000/my-app:v1.0.0
```

### 이미지 목록 확인

```bash
# Registry API로 확인
curl -u push-user:PASSWORD http://localhost:5000/v2/_catalog
curl -u push-user:PASSWORD http://localhost:5000/v2/my-app/tags/list
```

### 이미지 Pull (K8s에서)

앱 Deployment에서 `imagePullSecrets`를 지정하면 된다. 자세한 내용은 [4. 앱을 Kubernetes에 배포하기](#4-앱을-kubernetes에-배포하기) 참조.

---

## 4. 앱을 Kubernetes에 배포하기

개발한 앱을 K8s에 배포하는 전체 흐름이다.

### 4-1. 앱 디렉토리 구조 만들기

1000개 규모에서는 앱을 바로 `base/app/` 아래에 두지 않는다. unit, domain, workload kind, workload를 나눠 `k8s/base/app/units/<unit>/<domain>/<workload-kind>/<workload>/` 아래에 매니페스트를 작성한다:

```
k8s/base/app/units/commerce/checkout/services/my-app/
├── deployment.yaml
├── service.yaml
└── kustomization.yaml
```

### 4-2. Deployment 작성

```yaml
# k8s/base/app/units/commerce/checkout/services/my-app/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: app
  labels:
    app: my-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      imagePullSecrets:
        - name: registry-pull-credential
      containers:
        - name: my-app
          image: docker-registry.mnt.svc.cluster.local:5000/my-app:v1.0.0
          ports:
            - containerPort: 8080
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: my-app-secrets
                  key: DB_PASSWORD
```

핵심 포인트:
- `namespace: app` — 앱은 `app` 네임스페이스에 배포
- `imagePullSecrets` — Registry 인증용 (VSO가 자동 생성)
- `image` — 클러스터 내부 Registry 주소 사용
- `env` — Vault에서 동기화된 Secret을 환경변수로 주입

### 4-3. Service 작성

```yaml
# k8s/base/app/units/commerce/checkout/services/my-app/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: app
spec:
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

### 4-4. Kustomization 작성

```yaml
# k8s/base/app/units/commerce/checkout/services/my-app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
```

### 4-5. imagePullSecret을 app 네임스페이스에 생성

Registry 인증 Secret은 `mnt` 네임스페이스에 있으므로, `app` 네임스페이스에도 만들어야 한다.

`k8s/base/app/units/commerce/checkout/services/my-app/` 에 VaultStaticSecret을 추가한다:

```yaml
# k8s/base/app/units/commerce/checkout/services/my-app/vault-static-secret-pull-cred.yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: registry-pull-credential
  namespace: app
spec:
  vaultAuthRef: mnt/vault-auth
  mount: secret
  type: kv-v2
  path: docker-registry/pull-credentials
  refreshAfter: 1h
  destination:
    name: registry-pull-credential
    create: true
    type: kubernetes.io/dockerconfigjson
    transformation:
      templates:
        .dockerconfigjson:
          text: |
            {
              "auths": {
                "docker-registry.mnt.svc.cluster.local:5000": {
                  "username": "{{ get .Secrets "username" }}",
                  "password": "{{ get .Secrets "password" }}",
                  "auth": "{{ printf "%s:%s" (get .Secrets "username") (get .Secrets "password") | b64enc }}"
                }
              }
            }
```

kustomization.yaml에 추가:

```yaml
resources:
  - deployment.yaml
  - service.yaml
  - vault-static-secret-pull-cred.yaml
```

### 4-6. 배포

```bash
# 이미지 빌드 & Push
docker build -t my-app:v1.0.0 .
docker tag my-app:v1.0.0 localhost:5000/my-app:v1.0.0
docker push localhost:5000/my-app:v1.0.0

# K8s에 배포
kubectl apply -k k8s/base/app/units/commerce/checkout/services/my-app/

# 확인
kubectl get pods -n app
kubectl logs -n app -l app=my-app
```

### 4-7. 이미지 업데이트 (재배포)

```bash
# 새 버전 빌드 & Push
docker build -t my-app:v1.1.0 .
docker tag my-app:v1.1.0 localhost:5000/my-app:v1.1.0
docker push localhost:5000/my-app:v1.1.0

# deployment.yaml에서 이미지 태그 수정 후
kubectl apply -k k8s/base/app/units/commerce/checkout/services/my-app/

# 또는 직접 이미지 변경
kubectl set image deployment/my-app my-app=docker-registry.mnt.svc.cluster.local:5000/my-app:v1.1.0 -n app
```

---

## 5. 시크릿을 앱에서 사용하기

### 5-1. Vault에 앱 시크릿 저장

Vault UI 또는 CLI에서:

```bash
kubectl exec -it vault-0 -n mnt -- /bin/sh
vault login <root-token>

vault kv put secret/my-app/config \
  DB_HOST="db.mnt.svc.cluster.local" \
  DB_PASSWORD="secure-password" \
  API_KEY="ak-xxxxxxxxxxxx"
```

### 5-2. VSO Policy에 앱 경로 추가

Vault UI의 **Policies** > `vault-secrets-operator` > **Edit policy**에서 앱 경로를 추가하거나, CLI로:

```bash
vault policy write vault-secrets-operator - <<EOF
path "secret/data/docker-registry/*" {
  capabilities = ["read"]
}
path "secret/data/my-app/*" {
  capabilities = ["read"]
}
EOF
```

### 5-3. VaultStaticSecret 작성

```yaml
# k8s/base/app/units/commerce/checkout/services/my-app/vault-static-secret.yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: my-app-secrets
  namespace: app
spec:
  vaultAuthRef: mnt/vault-auth
  mount: secret
  type: kv-v2
  path: my-app/config
  refreshAfter: 1h
  destination:
    name: my-app-secrets
    create: true
```

이걸 apply하면 VSO가 Vault에서 값을 읽어 `my-app-secrets`라는 K8s Secret을 `app` 네임스페이스에 자동 생성한다.

### 5-4. Deployment에서 참조

**환경변수로 주입:**

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: my-app-secrets
        key: DB_PASSWORD
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: my-app-secrets
        key: API_KEY
```

**전체 Secret을 환경변수로:**

```yaml
envFrom:
  - secretRef:
      name: my-app-secrets
```

**파일로 마운트:**

```yaml
volumeMounts:
  - name: secrets
    mountPath: /etc/secrets
    readOnly: true
volumes:
  - name: secrets
    secret:
      secretName: my-app-secrets
```

### 5-5. 시크릿 변경 반영

1. Vault UI 또는 CLI에서 값 변경
2. VSO가 `refreshAfter: 1h` 간격으로 자동 반영
3. **즉시 반영이 필요하면** Pod를 재시작:

```bash
kubectl rollout restart deployment/my-app -n app
```

---

## 6. 환경별 배포

### Kustomize 패키지 규칙

- `k8s/base/<domain>/`은 공통 리소스 정의와 `kustomization.yaml` 진입점을 가진다.
- `k8s/overlays/<env>/<domain>/`은 같은 domain의 base를 재사용하고 환경별 patch만 둔다.
- `k8s/overlays/<env>/`는 환경 단위 집계 진입점이다.
- `managing/vault-secrets-operator/`는 Helm으로 VSO CRD가 준비된 뒤 적용하는 별도 phase 진입점이다.
- 앱은 `k8s/base/app/units/<unit>/<domain>/<workload-kind>/<workload>/` 단위로 추가한다.
- 환경 차이가 있는 앱만 `k8s/overlays/<env>/app/units/<unit>/<domain>/<workload-kind>/<workload>/`에 overlay를 둔다.

### 환경별 overlay 적용

```bash
# dev
kubectl apply -k k8s/overlays/dev/managing/
kubectl apply -k k8s/overlays/dev/managing/vault-secrets-operator/

# staging
kubectl apply -k k8s/overlays/staging/managing/
kubectl apply -k k8s/overlays/staging/managing/vault-secrets-operator/

# prod
kubectl apply -k k8s/overlays/prod/managing/
kubectl apply -k k8s/overlays/prod/managing/vault-secrets-operator/
```

또는 셋업 스크립트 사용:

```bash
k8s/scripts/env/bootstrap.sh dev      # dev 환경
k8s/scripts/env/bootstrap.sh staging  # staging 환경
k8s/scripts/env/bootstrap.sh prod     # prod 환경
```

전체 namespace/domain 골격을 한 번에 확인하거나 적용해야 할 때는 `k8s/overlays/<env>/`를 사용할 수 있다. 운영 셋업은 Vault 초기화와 VSO CRD 설치 순서가 필요하므로 위의 phase 순서를 따른다.

### 앱 환경별 overlay 만들기

```
k8s/overlays/dev/app/units/commerce/checkout/services/my-app/
└── kustomization.yaml
```

```yaml
# k8s/overlays/dev/app/units/commerce/checkout/services/my-app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../../../../../../../base/app/units/commerce/checkout/services/my-app

patches:
  - target:
      kind: Deployment
      name: my-app
    patch: |
      - op: replace
        path: /spec/replicas
        value: 1
```

```bash
kubectl apply -k k8s/overlays/dev/app/units/commerce/checkout/services/my-app/
```

### 환경별 리소스 요약

| 리소스 | dev | staging | prod |
|--------|-----|---------|------|
| Registry Replicas | 1 | 1 | 2 |
| Registry Storage | 5Gi | 10Gi | 50Gi |
| Vault Replicas | 1 | 1 | 3 (HA) |
| Vault Storage | 1Gi | 5Gi | 20Gi |

---

## 7. 트러블슈팅

### Vault Pod가 CrashLoopBackOff

```bash
kubectl logs vault-0 -n mnt
```

**`bind: address already in use` 에러:**

Vault config를 `VAULT_LOCAL_CONFIG` 환경변수로 주입하면 dev 모드 기본 listener(8200)와 충돌한다. ConfigMap을 파일(`vault-config.hcl`)로 마운트하고 `vault server -config=` 명령으로 production mode 실행해야 한다.

올바른 방식:
```yaml
# ConfigMap
data:
  vault-config.hcl: |
    storage "file" { path = "/vault/data" }
    listener "tcp" { address = "0.0.0.0:8200"; tls_disable = 1 }
    ui = true

# StatefulSet
command: ["vault", "server", "-config=/vault/config/vault-config.hcl"]
volumeMounts:
  - name: vault-config
    mountPath: /vault/config
    readOnly: true
```

잘못된 방식 (사용 금지):
```yaml
# envFrom으로 VAULT_LOCAL_CONFIG 주입 → 포트 충돌 발생
envFrom:
  - configMapRef:
      name: vault-config
```

### Vault Pod가 뜨지 않음 (기타)

```bash
kubectl describe pod vault-0 -n mnt
kubectl logs vault-0 -n mnt
```

### Vault가 Sealed 상태

Vault Pod가 재시작되면 Sealed 상태로 돌아간다. Unseal 필요:

```bash
# vault-init-keys.json에서 키 확인
KEYS=$(jq -r '.unseal_keys_b64[:3][]' vault-init-keys.json)
for KEY in $KEYS; do
  kubectl exec -n mnt vault-0 -- vault operator unseal "$KEY"
done
```

### VSO가 Secret을 생성하지 않음

```bash
# VSO Pod 로그 확인
kubectl logs -n mnt -l app.kubernetes.io/name=vault-secrets-operator

# VaultStaticSecret 상태 확인
kubectl get vaultstaticsecrets -n mnt
kubectl describe vaultstaticsecret docker-registry-htpasswd -n mnt
```

주요 원인:

**`403 permission denied` (VaultClientConfigError):**

1. **Vault kubernetes auth에 CA cert/token 누락** — `k8s/scripts/vault/init.sh`에서 `kubernetes_ca_cert`와 `token_reviewer_jwt`를 설정했는지 확인:
   ```bash
   kubectl exec -n mnt vault-0 -- vault read auth/kubernetes/config
   # kubernetes_ca_cert이 비어있으면 재설정 필요:
   kubectl exec -n mnt vault-0 -- sh -c 'vault write auth/kubernetes/config \
     kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
     kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
     token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token'
   ```

2. **ClusterRoleBinding 누락** — Vault SA에 `system:auth-delegator` 권한이 없으면 TokenReview API 호출 실패:
   ```bash
   kubectl get clusterrolebinding vault-tokenreview-binding
   # 없으면:
   kubectl apply -k k8s/overlays/<env>/managing/
   ```

3. **VSO Policy에 해당 경로 권한 없음**

4. **VaultAuth의 ServiceAccount/Role 설정 불일치**

기타 원인:
- Vault가 Sealed 상태
- VaultConnection의 address가 잘못됨

### 이미지 Pull 실패

```bash
# Pod 이벤트 확인
kubectl describe pod <pod-name> -n app

# imagePullSecret 존재 확인
kubectl get secret registry-pull-credential -n app

# Secret 내용 확인
kubectl get secret registry-pull-credential -n app -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

주요 원인:
- `registry-pull-credential` Secret이 해당 네임스페이스에 없음 → VaultStaticSecret 추가
- Registry 서비스 주소 오타
- htpasswd 계정 정보 불일치

### Registry Push 실패

```bash
# Registry Pod 로그 확인
kubectl logs -n mnt -l app=docker-registry

# 인증 확인
curl -u push-user:PASSWORD http://localhost:5000/v2/
# 200이면 정상, 401이면 인증 실패
```

주요 원인:
- port-forward가 끊어짐
- push-user 비밀번호 불일치
- PVC 용량 부족

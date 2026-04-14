# Project-Infra

Kubernetes 기반 인프라 구성 프로젝트. 클러스터 내 Private Docker Registry와 HashiCorp Vault를 운영하며, Vault Secrets Operator(VSO)로 시크릿을 자동 동기화한다. Kustomize를 통해 dev/staging/prod 환경을 분리 관리한다.

> **운영 가이드**: 인프라 셋업, 앱 배포, 시크릿 관리 등 실제 사용법은 [guide.md](guide.md)를 참조한다.

---

## 목차

1. [폴더 구조](#폴더-구조)
2. [네임스페이스 구조](#네임스페이스-구조)
3. [Docker Registry](#docker-registry)
4. [Vault](#vault)
5. [Vault Secrets Operator (VSO)](#vault-secrets-operator-vso)
6. [셋업 순서](#셋업-순서)
7. [환경별 배포](#환경별-배포)

---

## 폴더 구조

```
Project-Infra/
├── k8s/
│   ├── base/
│   │   ├── managing/                                   # NS: mnt
│   │   │   ├── namespace/
│   │   │   │   ├── namespace.yaml
│   │   │   │   └── kustomization.yaml
│   │   │   ├── docker-registry/
│   │   │   │   ├── deployment.yaml                     # registry:2 + htpasswd 인증
│   │   │   │   ├── service.yaml                        # ClusterIP (포트 5000)
│   │   │   │   ├── pvc.yaml                            # PVC (10Gi)
│   │   │   │   ├── configmap.yaml                      # Registry 설정
│   │   │   │   └── kustomization.yaml
│   │   │   ├── vault/
│   │   │   │   ├── statefulset.yaml                    # vault:1.15 (production mode)
│   │   │   │   ├── service.yaml                        # ClusterIP (8200, 8201)
│   │   │   │   ├── service-ui.yaml                     # NodePort 30820
│   │   │   │   ├── serviceaccount.yaml
│   │   │   │   ├── clusterrolebinding.yaml             # system:auth-delegator (TokenReview 권한)
│   │   │   │   ├── configmap.yaml                      # vault-config.hcl (파일 마운트)
│   │   │   │   └── kustomization.yaml
│   │   │   ├── vault-secrets-operator/
│   │   │   │   ├── serviceaccount.yaml                 # VSO Vault 인증용 SA
│   │   │   │   ├── vault-connection.yaml               # VaultConnection CR
│   │   │   │   ├── vault-auth.yaml                     # VaultAuth CR
│   │   │   │   ├── vault-static-secret-htpasswd.yaml   # VSO: Vault → htpasswd Secret
│   │   │   │   ├── vault-static-secret-pull-cred.yaml  # VSO: Vault → imagePullSecret
│   │   │   │   └── kustomization.yaml
│   │   │   └── kustomization.yaml
│   │   ├── app/                                        # NS: app
│   │   │   ├── units/                                  # 1000개 서비스 확장 경계
│   │   │   │   ├── kustomization.yaml
│   │   │   │   └── README.md
│   │   │   ├── shared/                                 # app namespace 공통 리소스
│   │   │   │   ├── kustomization.yaml
│   │   │   │   └── README.md
│   │   │   ├── namespace.yaml
│   │   │   ├── kustomization.yaml
│   │   │   └── README.md
│   │   └── plugins/                                    # NS: plugins
│   │       ├── namespace.yaml
│   │       └── kustomization.yaml
│   ├── overlays/                                       # 환경별 Kustomize 오버라이드
│   │   ├── dev/
│   │   │   ├── app/
│   │   │   │   └── units/
│   │   │   ├── managing/                               # dev 패치
│   │   │   ├── plugins/
│   │   │   └── kustomization.yaml
│   │   ├── staging/
│   │   │   ├── app/
│   │   │   │   └── units/
│   │   │   ├── managing/                               # staging (base 동일)
│   │   │   ├── plugins/
│   │   │   └── kustomization.yaml
│   │   └── prod/
│   │       ├── app/
│   │       │   └── units/
│   │       ├── managing/                               # prod 패치 (HA, 대용량)
│   │       ├── plugins/
│   │       └── kustomization.yaml
│   ├── vso/                                            # VSO 설치 lifecycle
│   │   ├── README.md
│   │   └── helm/vault-secrets-operator/
│   │       ├── values.yaml
│   │       └── install.sh
│   ├── scripts/                                        # bootstrap / break-glass 작업
│   │   ├── env/
│   │   │   ├── bootstrap.sh
│   │   │   └── teardown.sh
│   │   └── vault/
│   │       ├── init.sh
│   │       └── seed-registry.sh
│   └── README.md
├── guide.md                                            # 운영 가이드
├── terraform/
│   ├── environments/
│   │   ├── dev/README.md
│   │   ├── staging/README.md
│   │   ├── prod/README.md
│   │   └── README.md
│   ├── modules/
│   │   ├── compute/README.md
│   │   ├── database/README.md
│   │   ├── networking/README.md
│   │   ├── storage/README.md
│   │   └── README.md
│   └── README.md
└── README.md
```

---

## 네임스페이스 구조

| 디렉토리 | 네임스페이스 | 용도 |
|----------|-------------|------|
| `base/managing/` | `mnt` | 인프라 관리 (Registry, Vault, VSO) |
| `base/app/` | `app` | 애플리케이션 서비스 |
| `base/plugins/` | `plugins` | 플러그인 |

### 패키지 진입 규칙

- `k8s/base/<domain>/`은 공통 리소스 정의만 포함하고 `kustomization.yaml`을 진입점으로 둔다.
- `k8s/overlays/<env>/<domain>/`은 같은 domain의 base를 재사용하고 환경별 patch만 둔다.
- `k8s/overlays/<env>/kustomization.yaml`은 환경 단위 집계 진입점이다.
- `k8s/overlays/<env>/managing/`은 `base/managing`을 한 번만 조합한다. Docker Registry와 Vault의 하위 리소스 조합은 base가 소유한다.
- `vault-secrets-operator` CR 리소스는 Helm으로 CRD가 준비된 뒤 적용해야 하므로 `managing/vault-secrets-operator/`를 별도 phase 진입점으로 유지한다.
- 애플리케이션 워크로드는 `k8s/base/app/units/<unit>/<domain>/<workload-kind>/<workload>/` 아래에 둔다. 1000개 규모에서도 kind별 top-level 폴더가 아니라 ownership/workload 경계로 확장한다.
- 스크립트는 `k8s/scripts/`에 두고 bootstrap 또는 break-glass 작업만 담당한다. 서비스마다 스크립트를 만들지 않는다.

---

## Docker Registry

클러스터 내부에 Private Docker Registry(`registry:2`)를 운영한다.

### 구성 요약

| 항목 | 값 |
|------|---|
| 이미지 | `registry:2` |
| 네임스페이스 | `mnt` |
| 서비스 주소 | `docker-registry.mnt.svc.cluster.local:5000` |
| 인증 방식 | htpasswd (`/auth/htpasswd` 마운트) |
| 스토리지 | PVC 10Gi |

### 인증 구조

```
Vault (secret/docker-registry/auth)
  └─ VaultStaticSecret → K8s Secret: docker-registry-htpasswd
       └─ Registry Pod /auth/htpasswd 마운트

Vault (secret/docker-registry/pull-credentials)
  └─ VaultStaticSecret → K8s Secret: registry-pull-credential (dockerconfigjson)
       └─ App Pod imagePullSecrets 참조
```

### 이미지 Push/Pull

```bash
# Push
docker tag my-app:v1.0.0 docker-registry.mnt.svc.cluster.local:5000/my-app:v1.0.0
docker login docker-registry.mnt.svc.cluster.local:5000
docker push docker-registry.mnt.svc.cluster.local:5000/my-app:v1.0.0
```

```yaml
# Pull — Deployment 예시
spec:
  imagePullSecrets:
    - name: registry-pull-credential
  containers:
    - name: my-app
      image: docker-registry.mnt.svc.cluster.local:5000/my-app:v1.0.0
```

---

## Vault

| 항목 | 값 |
|------|---|
| 이미지 | `hashicorp/vault:1.15` |
| 네임스페이스 | `mnt` |
| 배포 형태 | StatefulSet (production mode) |
| 실행 방식 | `vault server -config=/vault/config/vault-config.hcl` |
| 설정 마운트 | ConfigMap → `/vault/config/vault-config.hcl` |
| 내부 서비스 | `vault.mnt.svc.cluster.local:8200` |
| UI 접근 | `http://<노드IP>:30820/ui` |
| 스토리지 | File Storage, PVC 5Gi |
| RBAC | `system:auth-delegator` ClusterRoleBinding (TokenReview 권한) |

### Vault 설정 방식

Vault는 **production mode**로 실행한다. ConfigMap에 `vault-config.hcl` 파일을 정의하고 `/vault/config/`에 volume mount 한다. `VAULT_LOCAL_CONFIG` 환경변수 방식은 dev 모드 기본 listener와 포트 충돌을 일으키므로 사용하지 않는다.

### Kubernetes Auth 설정

`k8s/scripts/vault/init.sh`에서 Kubernetes Auth를 활성화할 때 반드시 다음을 포함해야 한다:

```bash
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
```

- `kubernetes_ca_cert` — Vault가 K8s API 호출 시 TLS 검증에 사용
- `token_reviewer_jwt` — Vault가 TokenReview API를 호출할 때 사용하는 JWT

이 값이 누락되면 VSO가 Vault에 로그인할 때 `403 permission denied` 에러가 발생한다.

또한 Vault ServiceAccount에 `system:auth-delegator` ClusterRoleBinding이 필요하다. 이것이 없으면 Vault가 K8s TokenReview API를 호출할 권한이 없어 VSO 인증이 실패한다.

---

## Vault Secrets Operator (VSO)

Vault 시크릿을 K8s Secret으로 자동 동기화하는 HashiCorp 공식 오퍼레이터.

### 배포 순서 (CRD 의존성)

VSO 리소스(`VaultConnection`, `VaultAuth`, `VaultStaticSecret`)는 CRD가 필요하므로 Helm 설치 후에 별도로 적용해야 한다. 기본 인프라 배포(`kubectl apply -k`)와 분리되어 있다.

```
Phase 1: kubectl apply -k (namespace, vault, registry)
Phase 2: scripts/vault/init.sh (Vault 초기화)
Phase 3: scripts/vault/seed-registry.sh (시크릿 저장)
Phase 4: helm install (VSO Operator + CRD 설치)
Phase 5: kubectl apply -k vault-secrets-operator/ (VaultAuth, VaultStaticSecret 등)
```

### VSO가 관리하는 Secret

| VaultStaticSecret | Vault 경로 | K8s Secret | 용도 |
|-------------------|-----------|------------|------|
| `vault-static-secret-htpasswd.yaml` | `secret/docker-registry/auth` | `docker-registry-htpasswd` | Registry htpasswd |
| `vault-static-secret-pull-cred.yaml` | `secret/docker-registry/pull-credentials` | `registry-pull-credential` | imagePullSecret |

`refreshAfter: 1h` — Vault 값 변경 시 1시간 내 자동 반영.

---

## 셋업 순서

### 자동 셋업 (권장)

```bash
# 전체 과정을 단계별로 실행하는 스크립트
k8s/scripts/env/bootstrap.sh dev
```

환경 인자: `dev`, `staging`, `prod`

### 수동 셋업

#### 1. 인프라 배포

```bash
kubectl apply -k k8s/overlays/dev/managing/
```

이 단계에서는 CRD가 필요 없는 핵심 인프라만 배포된다:
- `mnt` Namespace
- Vault StatefulSet + Service + ClusterRoleBinding
- Docker Registry Deployment + Service (Secret이 아직 없어 Pod는 Pending)

#### 2. Vault 초기화

```bash
# Vault Pod가 Running 될 때까지 대기
kubectl wait --for=condition=Ready pod/vault-0 -n mnt --timeout=120s

# 초기화 실행
k8s/scripts/vault/init.sh
```

스크립트가 수행하는 작업:
- Vault init + unseal (키는 `vault-init-keys.json`에 저장)
- KV v2 시크릿 엔진 활성화
- Kubernetes Auth Method 설정 (CA cert + token_reviewer_jwt 포함)
- VSO용 Policy/Role 생성

> **`vault-init-keys.json`은 반드시 안전한 곳에 백업할 것.** git에 커밋 금지.

#### 3. Docker Registry 시크릿 저장

```bash
k8s/scripts/vault/seed-registry.sh
```

push-user / pull-user 비밀번호를 입력하면 htpasswd 생성 + Vault 저장까지 자동 처리.

#### 4. VSO Helm 설치

```bash
k8s/vso/helm/vault-secrets-operator/install.sh
```

#### 5. VSO 리소스 배포

```bash
# VSO CRD가 준비될 때까지 대기
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault-secrets-operator -n mnt --timeout=120s

# VSO 리소스 적용
kubectl apply -k k8s/overlays/dev/managing/vault-secrets-operator/
```

#### 6. 확인

```bash
# Secret이 생성되었는지 확인
kubectl get secrets -n mnt

# docker-registry-htpasswd, registry-pull-credential 이 있으면 성공
# docker-registry Pod가 Running인지 확인
kubectl get pods -n mnt
```

---

## 환경별 배포

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

`k8s/overlays/<env>/`는 환경 단위 집계 진입점이다. VSO CR 리소스는 CRD 설치 이후 별도 phase로 적용한다.

### 환경별 리소스 요약

| 리소스 | dev | staging | prod |
|--------|-----|---------|------|
| Registry Replicas | 1 | 1 | 2 |
| Registry Storage | 5Gi | 10Gi | 50Gi |
| Vault Replicas | 1 | 1 | 3 (HA) |
| Vault Storage | 1Gi | 5Gi | 20Gi |

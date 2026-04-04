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
│   │   │   ├── namespace.yaml
│   │   │   ├── docker-registry/
│   │   │   │   ├── deployment.yaml                     # registry:2 + htpasswd 인증
│   │   │   │   ├── service.yaml                        # ClusterIP (포트 5000)
│   │   │   │   ├── pvc.yaml                            # PVC (10Gi)
│   │   │   │   ├── configmap.yaml                      # Registry 설정
│   │   │   │   ├── vault-static-secret-htpasswd.yaml   # VSO: Vault → htpasswd Secret
│   │   │   │   ├── vault-static-secret-pull-cred.yaml  # VSO: Vault → imagePullSecret
│   │   │   │   └── kustomization.yaml
│   │   │   ├── vault/
│   │   │   │   ├── statefulset.yaml                    # vault:1.15 StatefulSet
│   │   │   │   ├── service.yaml                        # ClusterIP (8200, 8201)
│   │   │   │   ├── service-ui.yaml                     # NodePort 30820
│   │   │   │   ├── serviceaccount.yaml
│   │   │   │   ├── configmap.yaml
│   │   │   │   ├── scripts/
│   │   │   │   │   ├── vault-init.sh                   # Vault 초기화 스크립트
│   │   │   │   │   └── vault-seed.sh                   # Registry 시크릿 저장 스크립트
│   │   │   │   └── kustomization.yaml
│   │   │   ├── vault-secrets-operator/
│   │   │   │   ├── serviceaccount.yaml                 # VSO Vault 인증용 SA
│   │   │   │   ├── vault-connection.yaml               # VaultConnection CR
│   │   │   │   ├── vault-auth.yaml                     # VaultAuth CR
│   │   │   │   └── kustomization.yaml
│   │   │   └── kustomization.yaml
│   │   ├── app/                                        # NS: app
│   │   │   └── namespace.yaml
│   │   └── plugins/                                    # NS: plugins
│   │       └── namespace.yaml
│   ├── overlays/                                       # 환경별 Kustomize 오버라이드
│   │   ├── dev/managing/                               # dev 패치
│   │   ├── staging/managing/                           # staging (base 동일)
│   │   └── prod/managing/                              # prod 패치 (HA, 대용량)
│   ├── helm/                                           # Helm 릴리즈 관리
│   │   └── vault-secrets-operator/
│   │       ├── values.yaml
│   │       └── install.sh
│   └── components/                                     # (예정)
├── guide.md                                            # 운영 가이드
├── terraform/
│   ├── environments/{dev,staging,prod}/
│   └── modules/{compute,database,networking,storage}/
└── README.md
```

---

## 네임스페이스 구조

| 디렉토리 | 네임스페이스 | 용도 |
|----------|-------------|------|
| `base/managing/` | `mnt` | 인프라 관리 (Registry, Vault, VSO) |
| `base/app/` | `app` | 애플리케이션 서비스 |
| `base/plugins/` | `plugins` | 플러그인 |

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
| 배포 형태 | StatefulSet |
| 내부 서비스 | `vault.mnt.svc.cluster.local:8200` |
| UI 접근 | `http://<노드IP>:30820/ui` |
| 스토리지 | File Storage, PVC 5Gi |

---

## Vault Secrets Operator (VSO)

Vault 시크릿을 K8s Secret으로 자동 동기화하는 HashiCorp 공식 오퍼레이터.

### VSO가 관리하는 Secret

| VaultStaticSecret | Vault 경로 | K8s Secret | 용도 |
|-------------------|-----------|------------|------|
| `vault-static-secret-htpasswd.yaml` | `secret/docker-registry/auth` | `docker-registry-htpasswd` | Registry htpasswd |
| `vault-static-secret-pull-cred.yaml` | `secret/docker-registry/pull-credentials` | `registry-pull-credential` | imagePullSecret |

`refreshAfter: 1h` — Vault 값 변경 시 1시간 내 자동 반영.

---

## 셋업 순서

### 1. 인프라 배포

```bash
kubectl apply -k k8s/base/managing/
```

### 2. Vault 초기화

```bash
k8s/base/managing/vault/scripts/vault-init.sh
```

스크립트가 수행하는 작업:
- Vault init + unseal (키는 `vault-init-keys.json`에 저장)
- KV v2 시크릿 엔진 활성화
- Kubernetes Auth Method 설정
- VSO용 Policy/Role 생성

### 3. Docker Registry 시크릿 저장

```bash
k8s/base/managing/vault/scripts/vault-seed.sh
```

스크립트가 수행하는 작업:
- push-user / pull-user 비밀번호 입력받기
- htpasswd 파일 생성
- Vault에 `secret/docker-registry/auth` (htpasswd) 저장
- Vault에 `secret/docker-registry/pull-credentials` (username/password) 저장

### 4. VSO Helm 설치

```bash
k8s/helm/vault-secrets-operator/install.sh
```

### 5. VSO 리소스 배포

```bash
kubectl apply -k k8s/base/managing/
# → VSO가 Vault에서 시크릿을 읽어 K8s Secret 자동 생성
```

---

## 환경별 배포

```bash
kubectl apply -k k8s/overlays/dev/managing/
kubectl apply -k k8s/overlays/staging/managing/
kubectl apply -k k8s/overlays/prod/managing/
```

### 환경별 리소스 요약

| 리소스 | dev | staging | prod |
|--------|-----|---------|------|
| Registry Replicas | 1 | 1 | 2 |
| Registry Storage | 5Gi | 10Gi | 50Gi |
| Vault Replicas | 1 | 1 | 3 (HA) |
| Vault Storage | 1Gi | 5Gi | 20Gi |

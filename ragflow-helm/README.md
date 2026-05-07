# RAGFlow Helm Chart (Vulcan)

Helm chart for self-hosted [RAGFlow](https://github.com/infiniflow/ragflow) (`infiniflow/ragflow:v0.24.0`) — OIDC auth, Traefik ingress, and bring-your-own OpenAI-compatible LLM. Part of the [`vulcan-ragflow`](../README.md) deployment repo. Originally built for the Vulcan RKE2 cluster at the **Digital Research Alliance of Canada** (Traefik + cert-manager + `nfs-client`), portable to any cluster with the same primitives.

For full deployment workflow, secret handling, and the `deploy-ragflow.sh` operator script, see the [parent repo README](../README.md). This document covers chart structure and values only.

- **Components:** RAGFlow web/api, Infinity (default doc engine), MySQL 8, MinIO, Valkey 8 (Redis-compatible)
- **Optional doc engines:** `elasticsearch`, `opensearch` (via `env.DOC_ENGINE`)
- **Requirements:** Kubernetes >= 1.24, Helm >= 3.10, Traefik CRDs, cert-manager, `nfs-client` StorageClass

## What's Vulcan-specific

This is **not** the upstream InfiniFlow chart. Customizations live in `templates/` and `values.yaml`:

- Traefik `IngressRoute` + cert-manager `Certificate` (instead of stock `Ingress`)
- `NetworkPolicy` resources locking down MySQL / MinIO / Valkey / Infinity to the RAGFlow pod
- `initContainer` (`patch-settings`) that applies runtime patches to fix:
  - OIDC `client_secret` env injection from `OIDC_CLIENT_SECRET`
  - OAuth `Bearer` header stripping + session-based fallback
  - `llm_service.py` tenant model bootstrap
- All stateful components consume the external `ragflow-secrets` Kubernetes Secret via `envFrom`
- Single-replica StatefulSets for backends (vertical-scale only — see parent README)

Quick check:

```bash
rg "patch-settings|OIDC_CLIENT_SECRET|Bearer|session-based fallback|llm_service|ragflow-secrets" templates
```

## Install

The supported path is `./deploy-ragflow.sh` from the repo root (see parent README). For manual installs:

```bash
# from repo root
helm upgrade --install ragflow ./ragflow-helm \
  --namespace ragflow --create-namespace \
  -f values-secret.yaml \
  --wait --timeout 10m
```

Uninstall:

```bash
helm uninstall ragflow -n ragflow
```

The `ragflow-secrets` Secret must exist in the namespace before install:

```bash
kubectl apply -f ragflow-secrets.yaml.secret
```

## Global Settings

- `global.repo`: Prepend a global image registry prefix for all images.
  - Replaces the registry part and keeps the image path (e.g., `quay.io/minio/minio` -> `registry.example.com/myproj/minio/minio`).
  - Example: `global.repo: "registry.example.com/myproj"`
- `global.imagePullSecrets`: List of image pull secrets applied to all Pods.

```yaml
global:
  repo: ""
  imagePullSecrets:
    - name: regcred
```

## External Secrets

Sensitive values are **not** stored in `values.yaml`. They live in the external `ragflow-secrets` Secret and are injected via `envFrom` into RAGFlow and the backend StatefulSets:

- `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD`
- `MINIO_PASSWORD`, `MINIO_ROOT_PASSWORD`
- `REDIS_PASSWORD`
- `OIDC_CLIENT_SECRET`
- `SECRET_KEY`

See `ragflow-secrets.yaml` in the repo root for the template.

## Backend Services (MySQL / MinIO / Redis)

In-cluster by default. Toggle with `*.enabled`. When disabled, provide host/port via `env.*`.

- **MySQL** (`mysql.enabled`, default `true`)
  - External: set `env.MYSQL_HOST`, `env.MYSQL_PORT` (default `3306`), `env.MYSQL_DBNAME` (default `rag_flow`), `env.MYSQL_USER` (default `root`). `MYSQL_PASSWORD` comes from `ragflow-secrets`.
- **MinIO** (`minio.enabled`, default `true`)
  - External: set `env.MINIO_HOST`, `env.MINIO_PORT` (default `9000`), `env.MINIO_ROOT_USER` (default `rag_flow`). `MINIO_PASSWORD` comes from `ragflow-secrets`.
- **Redis / Valkey** (`redis.enabled`, default `true`)
  - External: set `env.REDIS_HOST`, `env.REDIS_PORT` (default `6379`). `REDIS_PASSWORD` comes from `ragflow-secrets`.

When `*.enabled=true`, the chart renders the in-cluster StatefulSet and injects the corresponding `*_HOST` / `*_PORT` automatically.

## Document Engine Selection

Choose one of `infinity` (default), `elasticsearch`, or `opensearch` via `env.DOC_ENGINE`. The chart only renders the selected engine.

```yaml
env:
  DOC_ENGINE: infinity   # or: elasticsearch | opensearch
  ELASTIC_PASSWORD: "<es-pass>"      # if elasticsearch
  OPENSEARCH_PASSWORD: "<os-pass>"   # if opensearch
```

## Ingress (Traefik IngressRoute + cert-manager)

Stock `Ingress` is disabled. The chart uses Traefik's `IngressRoute` and a cert-manager `Certificate`:

```yaml
ingressRoute:
  enabled: true
  entryPoints: [websecure]
  host: ragflow.example.com
  tls:
    secretName: ragflow-tls
  serversTransport:
    enabled: true
    disableHTTP2: true
    forwardingTimeouts:
      dialTimeout: 30s
      idleConnTimeout: 300s
      responseHeaderTimeout: 300s

certificate:
  enabled: true
  commonName: ragflow.example.com
  dnsNames:
    - ragflow.example.com
  issuerRef:
    kind: ClusterIssuer
    name: example-cluster-issuer
  secretName: ragflow-tls
```

A standard `ingress:` block is still available (`ingress.enabled: true`) if you need to fall back to a non-Traefik environment.

## Network Policies

`networkPolicy.enabled: true` (default) restricts ingress on MySQL, MinIO, Valkey, and the chosen doc engine to the RAGFlow pod only.

## LLM and OIDC

Both are bring-your-own and configured under `ragflow.service_conf`, overridden per environment via `values-secret.yaml` (see parent README). Defaults in `values.yaml` are placeholders (`CHANGE_ME_*`, `example.com`).

- **LLM:** any OpenAI-API-compatible endpoint — set `api_key`, `base_url`, and the five model names under `default_models` (`chat_model`, `embedding_model`, `rerank_model`, `asr_model`, `image2text_model`). Works with vLLM, LiteLLM, Ollama, OpenRouter, OpenAI, etc.
- **OIDC:** any standards-compliant IdP — set `display_name`, `client_id`, `client_secret`, `issuer`, `scope`, `redirect_uri`.

## Validate the Chart

```bash
helm lint ./ragflow-helm
helm template ragflow ./ragflow-helm -f values-secret.yaml > rendered.yaml
```

## Notes

- Chart version: see `Chart.yaml` (`version`, `appVersion`).
- Single rendered Secret `<release>-ragflow-env-config` carries derived `*_HOST` / `*_PORT` plus non-sensitive env. Sensitive credentials remain in the external `ragflow-secrets` Secret.
- `global.repo` and `global.imagePullSecrets` apply to all Pods; per-component `*.image.pullSecrets` are merged with global.

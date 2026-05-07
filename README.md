<img src="./assets/ua_logo_green_rgb.png" alt="University of Alberta Logo" width="50%" />

# Vulcan Helm RAGFlow

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)

**Maintained by:** Rahim Khoja ([khoja1@ualberta.ca](mailto:khoja1@ualberta.ca)) & Karim Ali ([kali2@ualberta.ca](mailto:kali2@ualberta.ca))

## 🧰 Description

Helm chart for self-hosted **RAGFlow** — OIDC auth, Traefik ingress, and bring-your-own OpenAI-compatible LLM. Upload documents, chat with your knowledge base, own your stack.

A production Helm deployment of **RAGFlow** (`infiniflow/ragflow:v0.24.0`), originally built for the Vulcan RKE2 cluster at the **Digital Research Alliance of Canada**, but designed to be portable to any Kubernetes cluster with Traefik, cert-manager, and a ReadWriteMany StorageClass.

**What is RAGFlow?**
[RAGFlow](https://github.com/infiniflow/ragflow) is an open-source Retrieval-Augmented Generation (RAG) platform by InfiniFlow. Users upload documents — PDFs, Word files, spreadsheets, web pages — and RAGFlow handles parsing, chunking, embedding, vector search, and chat. The end result is a multi-tenant web UI where users can have AI-powered conversations with their own knowledge base, backed by whatever LLM you point it at.

**What this chart deploys**
A self-contained stack on `nfs-client` storage:

- **RAGFlow** web app + API (Deployment, 2–8 CPU, 8–16Gi RAM)
- **Infinity** vector document engine (StatefulSet, 50Gi)
- **MySQL 8** for metadata (StatefulSet, 20Gi)
- **MinIO** for document object storage (StatefulSet, 50Gi)
- **Valkey 8** (Redis-compatible) for cache and queues (StatefulSet, 2Gi)

Optional doc engine swap: `infinity` (default), `elasticsearch`, or `opensearch` via `env.DOC_ENGINE`.

**Does it scale?**
Not horizontally in any meaningful way. The RAGFlow app has `podAntiAffinity` configured so it could in theory run multiple replicas, but every backend (MySQL, MinIO, Valkey, Infinity) is a single-replica StatefulSet. This is built to be a stable single-node production deployment — vertical scaling via the resource limits in `values.yaml` is the supported path. True HA would need significant rework.

**What makes this different from upstream**
This is not the stock InfiniFlow chart. It ships with:

- OIDC login wired to any standards-compliant identity provider (issuer, client id/secret, scopes, redirect URI all configurable)
- Bring-your-own LLM — any OpenAI-API-compatible endpoint (vLLM, LiteLLM, Ollama, OpenRouter, OpenAI itself, etc.) configured via `api_key`, `base_url`, and per-role model names in `values-secret.yaml`
- Traefik `IngressRoute` + cert-manager `Certificate` for ingress and TLS
- `NetworkPolicy` resources locking down backend services to the RAGFlow pod
- Runtime patches applied via initContainer to fix upstream compatibility issues with the OIDC auth flow, `Bearer` token handling, and tenant model bootstrap

## 🏗️ What's Inside

This deployment repo includes:

* A customized Helm chart in `ragflow-helm/`
* Traefik-native ingress via `IngressRoute` + cert-manager `Certificate`
* Network policies for backend service access control
* Runtime patching in `templates/ragflow.yaml` for:
  * OIDC flow compatibility
  * `Bearer` token handling + session fallback
  * tenant model bootstrap in `llm_service.py`
* External secret wiring through `ragflow-secrets` via `envFrom`

## Repository Contents

- `ragflow-helm/`
  - Customized Helm chart that is used for deployment.
  - Includes Vulcan-specific settings: Traefik `IngressRoute`, cert-manager `Certificate`, network policies, and resource/storage sizing.
  - Includes custom RAGFlow runtime patching in `templates/ragflow.yaml` (OIDC/login and model bootstrap fixes).
- `deploy-ragflow.sh`
  - Operator script for deploy/redeploy.
  - Performs preflight checks, validates secret files, applies k8s secret manifest, dry-run, and install.
- `ragflow-secrets.yaml`
  - Safe secret template with `CHANGEME` placeholders only.
  - This file is intended to be copied to a local untracked file before deploy.
- `values-secret.yaml.example`
  - Helm override template for per-environment config: LLM API endpoint, model names, and OIDC settings.
- `.gitignore`
  - Prevents committing local secret files:
    - `ragflow-secrets.yaml.secret`
    - `values-secret.yaml`

## ✅ Key Deployment Behaviors

The chart currently deploys with these notable behaviors:

- initContainer `patch-settings` runtime patch flow
- OIDC `client_secret` env injection from `OIDC_CLIENT_SECRET`
- OAuth authorization header Bearer stripping + session fallback
- `llm_service.py` tenant model bootstrap patch
- external `ragflow-secrets` wired via `envFrom` to all stateful components
- Traefik `IngressRoute`, cert-manager `Certificate`, and `NetworkPolicy` resources

Quick checks in repo:

```bash
rg "patch-settings|OIDC_CLIENT_SECRET|Bearer|session-based fallback|llm_service|ragflow-secrets" ragflow-helm/templates
```

## Secrets Handling

Do not commit real secrets.

1. Create local secret files:

```bash
cp ragflow-secrets.yaml ragflow-secrets.yaml.secret
cp values-secret.yaml.example values-secret.yaml
```

2. Replace every `CHANGEME` in those local files.

3. Apply the populated secret manifest before install (the deploy script does this automatically):

```bash
kubectl apply -f ragflow-secrets.yaml.secret
```

## 📝 Required Value Checklist

Two files need to be filled in before first deploy.

**`ragflow-secrets.yaml.secret`** (Kubernetes Secret, applied directly with `kubectl`):

- `MYSQL_PASSWORD` and `MYSQL_ROOT_PASSWORD` (must match)
- `MINIO_PASSWORD` and `MINIO_ROOT_PASSWORD` (must match)
- `REDIS_PASSWORD`
- `OIDC_CLIENT_SECRET`
- `SECRET_KEY` (long random value)

**`values-secret.yaml`** (Helm overrides, passed via `-f`):

- LLM: `api_key`, `base_url`, and the five model names under `default_models`
- OIDC: `display_name`, `client_id`, `client_secret`, `issuer`, `scope`, `redirect_uri`

Also update the two variables at the top of `deploy-ragflow.sh` to match your environment:

```bash
CERT_ISSUER_NAME="your-cluster-issuer"
APP_URL="https://your-ragflow-domain"
```

If your domain or cert issuer differs from the chart defaults (`ragflow.example.com`, `example-cluster-issuer`), edit `ragflow-helm/values.yaml` directly under the `ingressRoute` and `certificate` sections.

## Deploy

Clone and run from repo root:

```bash
git clone https://github.com/ualberta-rcg/vulcan-ragflow.git
cd vulcan-ragflow
chmod +x ./deploy-ragflow.sh
./deploy-ragflow.sh
```

The script:

- Checks cluster prerequisites (storageclass, Traefik CRDs, cert-manager, ClusterIssuer)
- Validates both secret files exist and have no `CHANGEME` placeholders
- Applies `ragflow-secrets.yaml.secret` as a Kubernetes Secret
- Lints the chart, runs a dry-run, then prompts before installing
- Requires `ragflow-secrets.yaml.secret` and `values-secret.yaml` to be present and fully populated

## 🔁 Operational Notes

`deploy-ragflow.sh` performs a fresh reinstall flow when a prior release exists (uninstall + PVC delete). Use it when you intentionally want a clean redeploy.

For in-place updates instead, run Helm upgrade manually:

```bash
helm upgrade ragflow ./ragflow-helm -n ragflow -f values-secret.yaml --wait --timeout 10m
```

## 🤝 Support

Many Bothans died to bring us this information. This project is provided as-is, but reasonable questions may be answered based on my coffee intake or mood. ;)

Feel free to open an issue or email **[khoja1@ualberta.ca](mailto:khoja1@ualberta.ca)** or **[kali2@ualberta.ca](mailto:kali2@ualberta.ca)** for U of A related deployments.

## 📜 License

This project is released under the **MIT License** - one of the most permissive open-source licenses available.

**What this means:**
- ✅ Use it for anything (personal, commercial, whatever)
- ✅ Modify it however you want
- ✅ Distribute it freely
- ✅ Include it in proprietary software

**The only requirement:** Keep the copyright notice somewhere in your project.

That's it! No other strings attached. The MIT License is trusted by major projects worldwide and removes virtually all legal barriers to using this code.

**Full license text:** [MIT License](./LICENSE)

## 🧠 About University of Alberta Research Computing

The [Research Computing Group](https://www.ualberta.ca/en/information-services-and-technology/research-computing/index.html) supports high-performance computing, data-intensive research, and advanced infrastructure for researchers at the University of Alberta and across Canada.

We help design and operate compute environments that power innovation — from AI training clusters to national research infrastructure.

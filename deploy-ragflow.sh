#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# RAGFlow Deployment Script for Vulcan RKE2 Cluster
#=============================================================================
#
# PREREQUISITES:
# -----------------------------------------------------------------------
# 1. ragflow-secrets.yaml.secret  — DB/MinIO/Redis/OIDC passwords (gitignored)
# 2. values-secret.yaml           — LLM API, model names, OIDC config (gitignored)
#    Both must have all CHANGEME placeholders replaced with real values.
#
# 3. Update CERT_ISSUER_NAME and APP_URL below to match your environment.
#
# 4. LLM models and API endpoint are configured via values-secret.yaml.
#    No manual UI setup needed after deploy.
#
# 5. OIDC is configured via values-secret.yaml. On first deploy, password
#    login is still enabled (DISABLE_PASSWORD_LOGIN=false) so admin can log in.
#    Flip to "true" after verifying OIDC works.
#
#=============================================================================

NAMESPACE="ragflow"
RELEASE_NAME="ragflow"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/ragflow-helm"
SECRETS_FILE="${SCRIPT_DIR}/ragflow-secrets.yaml.secret"
VALUES_SECRET="${SCRIPT_DIR}/values-secret.yaml"
CERT_ISSUER_NAME="example-cluster-issuer"   # EG letsencrypt-dns
APP_URL="https://ragflow.example.com"

echo "============================================="
echo " RAGFlow Deployment"
echo " Namespace: ${NAMESPACE}"
echo " Chart:     ${CHART_DIR}"
echo "============================================="

# --- Pre-flight checks ---
echo ""
echo "[1/8] Pre-flight checks..."

for cmd in helm kubectl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is not installed or not in PATH"
        exit 1
    fi
done

if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "  - helm $(helm version --short 2>/dev/null)"
echo "  - kubectl connected to cluster"

for resource in "storageclass/nfs-client" "crd/ingressroutes.traefik.io" "crd/certificates.cert-manager.io" "clusterissuer/${CERT_ISSUER_NAME}"; do
    if ! kubectl get "$resource" &>/dev/null; then
        echo "ERROR: $resource not found"
        exit 1
    fi
    echo "  - ${resource##*/} available"
done

# Verify secrets files exist and have no CHANGEME
for f in "${SECRETS_FILE}" "${VALUES_SECRET}"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: $f not found."
        exit 1
    fi
    if grep -q 'CHANGEME' "$f"; then
        echo "ERROR: $f still contains 'CHANGEME' placeholders."
        exit 1
    fi
    echo "  - $(basename "$f") ready"
done

# --- Tear down existing release if present ---
echo ""
echo "[2/8] Checking for existing release..."
if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    echo "  Existing release found. Uninstalling for fresh start..."
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait
    echo "  - Helm release removed"

    echo "  Deleting PVCs (fresh databases required for LLM pre-config)..."
    kubectl delete pvc --all -n "${NAMESPACE}" --wait=false 2>/dev/null || true
    sleep 5
    echo "  - PVCs deleted"
fi

# --- Apply secrets (creates namespace + secret) ---
echo ""
echo "[3/8] Applying secrets (namespace + ragflow-secrets)..."
kubectl apply -f "${SECRETS_FILE}"

# --- Lint chart ---
echo ""
echo "[4/8] Linting chart..."
helm lint "${CHART_DIR}" --namespace "${NAMESPACE}"

# --- Dry run ---
echo ""
echo "[5/8] Dry-run install..."
helm install "${RELEASE_NAME}" "${CHART_DIR}" \
    --namespace "${NAMESPACE}" \
    -f "${VALUES_SECRET}" \
    --dry-run \
    --debug 2>&1 | tail -5

echo ""
echo "  Dry-run passed."

# --- Actual install ---
echo ""
echo "[6/8] Installing RAGFlow..."
echo ""
read -rp "Proceed with helm install? (y/N): " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

helm install "${RELEASE_NAME}" "${CHART_DIR}" \
    --namespace "${NAMESPACE}" \
    -f "${VALUES_SECRET}" \
    --wait \
    --timeout 10m

# --- Wait for pods ---
echo ""
echo "[7/8] Waiting for pods to become ready..."
echo ""
kubectl -n "${NAMESPACE}" rollout status deployment/"${RELEASE_NAME}" --timeout=300s 2>/dev/null || true
echo ""
kubectl get pods -n "${NAMESPACE}" -o wide

# --- Verify cert ---
echo ""
echo "[8/8] Certificate status..."
kubectl get certificate -n "${NAMESPACE}" 2>/dev/null || echo "  (no certificate resource found yet)"

echo ""
echo "============================================="
echo " Deployment complete!"
echo "============================================="
echo ""
echo "Check status:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get svc -n ${NAMESPACE}"
echo "  kubectl get ingressroute -n ${NAMESPACE}"
echo ""
echo "Certificate:"
echo "  kubectl get certificate -n ${NAMESPACE}"
echo ""
echo "Logs:"
echo "  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=ragflow -f"
echo ""
echo "Access:"
echo "  ${APP_URL}"
echo ""
echo "LLM models and API endpoint are configured via values-secret.yaml."
echo ""
echo "Default admin login:"
echo "  username: admin    password: admin"
echo "  ** Change the admin password immediately after first login **"
echo ""
echo "OIDC is configured via values-secret.yaml. Users will see the"
echo "configured identity provider login button."
echo ""
echo "After verifying OIDC works, disable password login:"
echo "  Set env.DISABLE_PASSWORD_LOGIN to 'true' in values.yaml"
echo "  Then: helm upgrade ragflow ragflow-helm -n ragflow -f values-secret.yaml"
echo ""

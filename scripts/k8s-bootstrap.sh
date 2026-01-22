#!/bin/bash

# =============================================================================
# ML Inference Infrastructure - Kubernetes Bootstrap Script
# =============================================================================
#
# This script deploys the complete ML inference infrastructure on Kubernetes:
#   - MinIO (S3-compatible storage)
#   - Redis (Feature caching)
#   - PostgreSQL (MLflow backend store)
#   - MLflow (Model registry & tracking)
#   - Prometheus + Grafana (Monitoring)
#   - Inference API (FastAPI application)
#
# TESTED: Docker Desktop Kubernetes (ARM64/Apple Silicon)
#
# Usage:
#   ./scripts/k8s-bootstrap.sh              # Deploy everything
#   ./scripts/k8s-bootstrap.sh --infra-only # Deploy infrastructure only
#   ./scripts/k8s-bootstrap.sh --api-only   # Deploy API only (requires infra)
#   ./scripts/k8s-bootstrap.sh --cleanup    # Remove all deployments
#   ./scripts/k8s-bootstrap.sh --status     # Show deployment status
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="${NAMESPACE:-ml-pipeline}"
RELEASE_PREFIX="${RELEASE_PREFIX:-ml}"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
K8S_DIR="$ROOT_DIR/k8s"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

check_prerequisites() {
    log_step "Checking Prerequisites"

    local missing_deps=()

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        missing_deps+=("kubectl")
    fi

    # Check helm
    if ! command -v helm &> /dev/null; then
        missing_deps+=("helm")
    fi

    # Check docker
    if ! command -v docker &> /dev/null; then
        missing_deps+=("docker")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Please install the missing tools and try again."
        exit 1
    fi

    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        log_info "Make sure your kubeconfig is set up correctly."
        log_info "For Docker Desktop: Enable Kubernetes in Docker Desktop settings."
        exit 1
    fi

    log_success "All prerequisites met."
}

add_helm_repos() {
    log_info "Adding Helm repositories..."

    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo add minio https://charts.min.io/ 2>/dev/null || true
    helm repo add community-charts https://community-charts.github.io/helm-charts 2>/dev/null || true
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
    helm repo update

    log_success "Helm repositories updated."
}

create_namespace() {
    log_info "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    log_success "Namespace ready."
}

wait_for_pods() {
    local label=$1
    local timeout=${2:-120}

    log_info "Waiting for pods with label '$label' to be ready..."
    kubectl wait --for=condition=ready pod -l "$label" -n "$NAMESPACE" --timeout="${timeout}s" 2>/dev/null || {
        log_warn "Some pods may not be ready yet. Continuing..."
    }
}

# Retry helper for helm commands (handles network timeouts)
helm_install_with_retry() {
    local max_attempts=3
    local attempt=1
    local cmd="$@"

    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt of $max_attempts..."
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Attempt $attempt failed. Retrying in 5 seconds..."
        sleep 5
        ((attempt++))
    done

    log_error "Failed after $max_attempts attempts"
    return 1
}

# =============================================================================
# Infrastructure Deployment Functions
# =============================================================================

deploy_minio() {
    log_step "Deploying MinIO"

    # Check if already deployed and running
    if kubectl get deployment minio -n "$NAMESPACE" &>/dev/null && \
       kubectl get pods -l app=minio -n "$NAMESPACE" 2>/dev/null | grep -q "Running"; then
        log_info "MinIO already running. Skipping..."
        return 0
    fi

    # Use direct K8s manifest with official minio/minio image (bitnami images are broken)
    kubectl apply -f "$ROOT_DIR/minio/k8s/minio.yaml" -n "$NAMESPACE"

    wait_for_pods "app=minio"
    log_success "MinIO deployed."
}

deploy_redis() {
    log_step "Deploying Redis"

    # Check if already deployed and running
    if helm status "${RELEASE_PREFIX}-redis" -n "$NAMESPACE" &>/dev/null && \
       kubectl get pods -l app.kubernetes.io/name=redis -n "$NAMESPACE" 2>/dev/null | grep -q "Running"; then
        log_info "Redis already running. Skipping..."
        return 0
    fi

    helm_install_with_retry "helm upgrade --install ${RELEASE_PREFIX}-redis bitnami/redis \
        --namespace $NAMESPACE \
        --values $ROOT_DIR/redis/values.yaml \
        --wait --timeout 5m"

    wait_for_pods "app.kubernetes.io/name=redis"
    log_success "Redis deployed."
}

deploy_postgresql() {
    log_step "Deploying PostgreSQL"

    # Check if already deployed and running
    if helm status postgresql -n "$NAMESPACE" &>/dev/null && \
       kubectl get pods -l app.kubernetes.io/name=postgresql -n "$NAMESPACE" 2>/dev/null | grep -q "Running"; then
        log_info "PostgreSQL already running. Skipping..."
        return 0
    fi

    # Deploy PostgreSQL using Helm with two databases:
    #   - mlflow: for MLflow experiment tracking
    #   - crypto: for ETL raw data from Binance
    helm_install_with_retry "helm upgrade --install postgresql bitnami/postgresql \
        --namespace $NAMESPACE \
        --values $ROOT_DIR/postgresql/values.yaml \
        --wait --timeout 5m"

    wait_for_pods "app.kubernetes.io/name=postgresql"
    log_success "PostgreSQL deployed (databases: mlflow, crypto)."
}

deploy_mlflow() {
    log_step "Deploying MLflow"

    # Check if already deployed and running
    if helm status "${RELEASE_PREFIX}-mlflow" -n "$NAMESPACE" &>/dev/null && \
       kubectl get pods -l app.kubernetes.io/name=mlflow -n "$NAMESPACE" 2>/dev/null | grep -q "Running"; then
        log_info "MLflow already running. Skipping..."
        return 0
    fi

    helm_install_with_retry "helm upgrade --install ${RELEASE_PREFIX}-mlflow community-charts/mlflow \
        --namespace $NAMESPACE \
        --values $ROOT_DIR/mlflow/values.yaml \
        --wait --timeout 10m"

    wait_for_pods "app.kubernetes.io/name=mlflow"
    log_success "MLflow deployed."
}

deploy_monitoring() {
    log_step "Deploying Prometheus + Grafana"

    # Check if already deployed and running
    if helm status "${RELEASE_PREFIX}-monitoring" -n "$NAMESPACE" &>/dev/null && \
       kubectl get pods -l app.kubernetes.io/name=grafana -n "$NAMESPACE" 2>/dev/null | grep -q "Running"; then
        log_info "Monitoring stack already running. Skipping..."
        return 0
    fi

    helm_install_with_retry "helm upgrade --install ${RELEASE_PREFIX}-monitoring prometheus-community/kube-prometheus-stack \
        --namespace $NAMESPACE \
        --values $ROOT_DIR/grafana/values.yaml \
        --wait --timeout 10m"

    wait_for_pods "app.kubernetes.io/name=grafana"
    log_success "Monitoring stack deployed."
}

setup_etl_database() {
    log_step "Setting up ETL Database (crypto)"

    # Check if crypto user exists
    log_info "Creating crypto user and database..."
    kubectl exec -n "$NAMESPACE" postgresql-0 -- bash -c "PGPASSWORD=postgres123 psql -U postgres -c \"CREATE USER crypto WITH ENCRYPTED PASSWORD 'crypto123';\"" 2>/dev/null || log_info "User 'crypto' may already exist"
    kubectl exec -n "$NAMESPACE" postgresql-0 -- bash -c "PGPASSWORD=postgres123 psql -U postgres -c \"CREATE DATABASE crypto OWNER crypto;\"" 2>/dev/null || log_info "Database 'crypto' may already exist"
    kubectl exec -n "$NAMESPACE" postgresql-0 -- bash -c "PGPASSWORD=postgres123 psql -U postgres -c \"ALTER DATABASE crypto OWNER TO crypto; GRANT ALL PRIVILEGES ON DATABASE crypto TO crypto;\""
    kubectl exec -n "$NAMESPACE" postgresql-0 -- bash -c "PGPASSWORD=postgres123 psql -U postgres -d crypto -c \"GRANT ALL ON SCHEMA public TO crypto;\""

    # Create crypto_data table (schema matches loader.py expectations)
    log_info "Creating crypto_data table..."
    kubectl exec -n "$NAMESPACE" postgresql-0 -- bash -c "PGPASSWORD=postgres123 psql -U postgres -d crypto -c \"
CREATE TABLE IF NOT EXISTS crypto_data (
    id SERIAL PRIMARY KEY,
    symbol TEXT NOT NULL,
    open_time BIGINT NOT NULL,
    close_time BIGINT NOT NULL,
    open_price REAL NOT NULL,
    high_price REAL NOT NULL,
    low_price REAL NOT NULL,
    close_price REAL NOT NULL,
    volume REAL NOT NULL,
    quote_volume REAL NOT NULL,
    trades_count INTEGER NOT NULL,
    buy_ratio REAL,
    batch_id TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(symbol, open_time)
);
CREATE INDEX IF NOT EXISTS idx_crypto_data_symbol ON crypto_data(symbol);
CREATE INDEX IF NOT EXISTS idx_crypto_data_open_time ON crypto_data(open_time);
CREATE INDEX IF NOT EXISTS idx_crypto_data_symbol_time ON crypto_data(symbol, open_time DESC);
GRANT ALL PRIVILEGES ON TABLE crypto_data TO crypto;
GRANT USAGE, SELECT ON SEQUENCE crypto_data_id_seq TO crypto;
\""

    log_success "ETL database configured."
}

setup_minio_buckets() {
    log_step "Setting up MinIO Buckets"

    # Wait for MinIO to be ready
    log_info "Waiting for MinIO to be ready..."
    sleep 5

    # Create buckets using a temporary pod
    log_info "Creating MinIO buckets..."
    kubectl run minio-setup --rm -i --restart=Never -n "$NAMESPACE" \
        --image=minio/mc:latest \
        --command -- /bin/sh -c "
            mc alias set myminio http://minio:9000 admin admin123 && \
            mc mb --ignore-existing myminio/crypto-raw-data && \
            mc mb --ignore-existing myminio/crypto-features && \
            mc mb --ignore-existing myminio/mlflow-artifacts && \
            echo 'Buckets created successfully'
        " 2>/dev/null || log_info "MinIO buckets may already exist"

    log_success "MinIO buckets configured."
}

deploy_airflow() {
    log_step "Deploying Apache Airflow"

    # Check if already deployed and running
    if helm status airflow -n "$NAMESPACE" &>/dev/null && \
       kubectl get pods -l component=scheduler -n "$NAMESPACE" 2>/dev/null | grep -q "Running"; then
        log_info "Airflow already running. Skipping..."
        return 0
    fi

    # Get image tag from values.yaml or use default
    local AIRFLOW_IMAGE_TAG=$(grep "tag:" "$ROOT_DIR/airflow/values.yaml" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'" || echo "0.0.4")
    if [ -z "$AIRFLOW_IMAGE_TAG" ]; then
        AIRFLOW_IMAGE_TAG="0.0.4"
    fi
    log_info "Using Airflow image tag: $AIRFLOW_IMAGE_TAG"

    # Ensure local registry is running for custom Airflow image
    log_info "Checking local Docker registry..."
    docker run -d -p 5050:5000 --name registry registry:2 2>/dev/null || docker start registry 2>/dev/null || true

    # Build and push custom Airflow image if not exists
    if ! docker images | grep -q "localhost:5050/custom-airflow.*$AIRFLOW_IMAGE_TAG"; then
        log_info "Building custom Airflow image..."
        docker build -t localhost:5050/custom-airflow:$AIRFLOW_IMAGE_TAG -f "$ROOT_DIR/docker/Dockerfile.airflow" "$ROOT_DIR"
    fi

    log_info "Pushing custom Airflow image to local registry..."
    docker push localhost:5050/custom-airflow:$AIRFLOW_IMAGE_TAG

    # Step 1: Create Airflow database and user in PostgreSQL
    log_info "Creating Airflow database and user in PostgreSQL..."
    kubectl exec -n "$NAMESPACE" postgresql-0 -- bash -c "PGPASSWORD=postgres123 psql -U postgres -c \"CREATE DATABASE airflow;\"" 2>/dev/null || log_info "Database 'airflow' may already exist"
    kubectl exec -n "$NAMESPACE" postgresql-0 -- bash -c "PGPASSWORD=postgres123 psql -U postgres -c \"CREATE USER airflow WITH ENCRYPTED PASSWORD 'airflow123';\"" 2>/dev/null || log_info "User 'airflow' may already exist"
    kubectl exec -n "$NAMESPACE" postgresql-0 -- bash -c "PGPASSWORD=postgres123 psql -U postgres -c \"ALTER DATABASE airflow OWNER TO airflow;\""
    kubectl exec -n "$NAMESPACE" postgresql-0 -- bash -c "PGPASSWORD=postgres123 psql -U postgres -d airflow -c \"GRANT ALL ON SCHEMA public TO airflow;\""
    log_success "Airflow database configured."

    # Step 2: Run Airflow DB migration job BEFORE deploying Airflow
    # Check if migration already completed
    if kubectl get job airflow-db-migrate -n "$NAMESPACE" &>/dev/null && \
       kubectl get job airflow-db-migrate -n "$NAMESPACE" -o jsonpath='{.status.succeeded}' | grep -q "1"; then
        log_info "Airflow migrations already completed. Skipping..."
    else
        # Delete old failed job if exists
        kubectl delete job airflow-db-migrate -n "$NAMESPACE" 2>/dev/null || true

        log_info "Running Airflow database migrations..."
        cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: airflow-db-migrate
  namespace: $NAMESPACE
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migrate
        image: localhost:5050/custom-airflow:$AIRFLOW_IMAGE_TAG
        imagePullPolicy: Always
        command: ["airflow", "db", "migrate"]
        env:
        - name: AIRFLOW__DATABASE__SQL_ALCHEMY_CONN
          value: "postgresql://airflow:airflow123@postgresql:5432/airflow"
EOF

        # Wait for migration to complete
        log_info "Waiting for migrations to complete..."
        kubectl wait --for=condition=complete job/airflow-db-migrate -n "$NAMESPACE" --timeout=120s
        log_success "Airflow database migrations completed."
    fi

    # Step 3: Deploy Airflow using Helm with chart version 1.18.0 (Airflow 3.0)
    # Note: values.yaml must have waitForMigrations.enabled: false for all components
    # (webserver, scheduler, triggerer, dagProcessor, apiServer)
    log_info "Deploying Airflow with Helm (chart version 1.18.0 for Airflow 3.0)..."
    helm_install_with_retry "helm upgrade --install airflow apache-airflow/airflow \
        --namespace $NAMESPACE \
        --values $ROOT_DIR/airflow/values.yaml \
        --version 1.18.0 \
        --wait --timeout 10m"

    wait_for_pods "component=scheduler"
    log_success "Airflow deployed."
}

configure_airflow_post_deploy() {
    log_step "Configuring Airflow Post-Deployment"

    # Step 1: Create session table for Airflow UI (Flask-Session)
    log_info "Creating session table for Airflow UI..."
    kubectl exec -n "$NAMESPACE" postgresql-0 -- bash -c "PGPASSWORD=postgres123 psql -U postgres -d airflow -c \"
CREATE TABLE IF NOT EXISTS session (
    id SERIAL PRIMARY KEY,
    session_id VARCHAR(255) UNIQUE NOT NULL,
    data BYTEA,
    expiry TIMESTAMP
);
CREATE INDEX IF NOT EXISTS ix_session_session_id ON session(session_id);
CREATE INDEX IF NOT EXISTS ix_session_expiry ON session(expiry);
GRANT ALL PRIVILEGES ON TABLE session TO airflow;
GRANT USAGE, SELECT ON SEQUENCE session_id_seq TO airflow;
\"" 2>/dev/null || log_info "Session table may already exist"

    # Step 2: Run FAB database migration
    log_info "Running FAB database migration..."
    kubectl exec -n "$NAMESPACE" deployment/airflow-api-server -- airflow fab-db migrate 2>/dev/null || log_info "FAB migration may have already run"

    # Step 3: Create Airflow pools for ETL pipeline
    log_info "Creating Airflow pools..."
    kubectl exec -n "$NAMESPACE" deployment/airflow-scheduler -- airflow pools set binance_api_pool 5 "Binance API rate limiting pool" 2>/dev/null || true
    kubectl exec -n "$NAMESPACE" deployment/airflow-scheduler -- airflow pools set postgres_pool 10 "PostgreSQL connection pool" 2>/dev/null || true

    # Step 4: Restart API server to pick up session table
    log_info "Restarting Airflow API server..."
    kubectl rollout restart deployment/airflow-api-server -n "$NAMESPACE"
    kubectl rollout status deployment/airflow-api-server -n "$NAMESPACE" --timeout=60s

    log_success "Airflow post-deployment configuration complete."
}

deploy_infrastructure() {
    log_step "Deploying Infrastructure Services"

    deploy_minio
    deploy_redis
    deploy_postgresql

    # Setup ETL database after PostgreSQL is ready
    setup_etl_database

    # Setup MinIO buckets after MinIO is ready
    setup_minio_buckets

    deploy_mlflow
    deploy_monitoring
    deploy_airflow

    # Configure Airflow after deployment (session table, pools, FAB migration)
    configure_airflow_post_deploy

    log_success "All infrastructure services deployed!"
}

# =============================================================================
# API Deployment Functions
# =============================================================================

build_api_image() {
    log_step "Building API Docker Image"

    docker build -t crypto-prediction-api:${IMAGE_TAG} \
        -f "$ROOT_DIR/docker/Dockerfile.inference" \
        "$ROOT_DIR"

    log_success "API image built: crypto-prediction-api:${IMAGE_TAG}"
}

create_secrets() {
    log_step "Creating Kubernetes Secrets"

    # Generate base64 encoded secrets
    DB_PASSWORD_B64=$(echo -n "mlflow123" | base64)
    MINIO_ACCESS_B64=$(echo -n "admin" | base64)
    MINIO_SECRET_B64=$(echo -n "admin123" | base64)
    REDIS_PASSWORD_B64=$(echo -n "redis123" | base64)

    cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: Secret
metadata:
  name: ml-pipeline-secrets
  labels:
    app: crypto-prediction-api
    component: secrets
type: Opaque
data:
  DB_PASSWORD: ${DB_PASSWORD_B64}
  MINIO_ACCESS_KEY: ${MINIO_ACCESS_B64}
  MINIO_SECRET_KEY: ${MINIO_SECRET_B64}
  REDIS_PASSWORD: ${REDIS_PASSWORD_B64}
EOF

    log_success "Secrets created."
}

deploy_api() {
    log_step "Deploying Inference API"

    build_api_image
    create_secrets

    # Apply API manifests using kustomize
    kubectl apply -k "$K8S_DIR"

    # Wait for deployment
    kubectl rollout status deployment/crypto-prediction-api -n "$NAMESPACE" --timeout=5m

    log_success "Inference API deployed."
}

# =============================================================================
# Status & Verification Functions
# =============================================================================

show_status() {
    log_step "Deployment Status"

    echo -e "${CYAN}Pods:${NC}"
    kubectl get pods -n "$NAMESPACE" -o wide
    echo ""

    echo -e "${CYAN}Services:${NC}"
    kubectl get svc -n "$NAMESPACE"
    echo ""

    echo -e "${CYAN}HPA:${NC}"
    kubectl get hpa -n "$NAMESPACE" 2>/dev/null || echo "No HPA found"
    echo ""
}

show_endpoints() {
    log_step "Service Access Information"

    echo -e "${CYAN}To access services, use port-forward:${NC}\n"
    echo "  Airflow:  kubectl port-forward -n $NAMESPACE svc/airflow-api-server 8080:8080"
    echo "  API:      kubectl port-forward -n $NAMESPACE svc/crypto-prediction-api 8000:8000"
    echo "  MLflow:   kubectl port-forward -n $NAMESPACE svc/${RELEASE_PREFIX}-mlflow 5000:5000"
    echo "  MinIO:    kubectl port-forward -n $NAMESPACE svc/minio 9000:9000 9001:9001"
    echo "  Grafana:  kubectl port-forward -n $NAMESPACE svc/${RELEASE_PREFIX}-monitoring-grafana 3000:80"
    echo ""
    echo -e "${CYAN}Access URLs (after port-forward):${NC}"
    echo "  Airflow UI:  http://localhost:8080"
    echo "  API Docs:    http://localhost:8000/docs"
    echo "  MLflow UI:   http://localhost:5000"
    echo "  MinIO UI:    http://localhost:9001"
    echo "  Grafana:     http://localhost:3000"
    echo ""
    echo -e "${CYAN}Default credentials:${NC}"
    echo "  Airflow: admin / admin123"
    echo "  MinIO:   admin / admin123"
    echo "  Grafana: admin / prom-operator (or check values.yaml)"
    echo "  MLflow:  No auth (open)"
    echo ""
}

verify_services() {
    log_step "Verifying Service Connectivity"

    local failed=0

    # Test API health
    log_info "Testing API..."
    kubectl exec -n "$NAMESPACE" deployment/crypto-prediction-api -- \
        curl -s http://localhost:8000/health > /dev/null 2>&1 && \
        log_success "API is healthy" || { log_error "API health check failed"; ((failed++)); }

    # Test MLflow
    log_info "Testing MLflow..."
    kubectl exec -n "$NAMESPACE" deployment/crypto-prediction-api -- \
        curl -s http://${RELEASE_PREFIX}-mlflow:5000/health > /dev/null 2>&1 && \
        log_success "MLflow is accessible" || { log_error "MLflow not accessible"; ((failed++)); }

    # Test MinIO
    log_info "Testing MinIO..."
    kubectl exec -n "$NAMESPACE" deployment/crypto-prediction-api -- \
        curl -s http://${RELEASE_PREFIX}-minio:9000/minio/health/live > /dev/null 2>&1 && \
        log_success "MinIO is accessible" || { log_warn "MinIO health check - may need different endpoint"; }

    # Test Redis
    log_info "Testing Redis..."
    kubectl exec -n "$NAMESPACE" deployment/crypto-prediction-api -- \
        python3 -c "import redis; r = redis.Redis(host='${RELEASE_PREFIX}-redis-master', port=6379, password='redis123'); print('OK' if r.ping() else 'FAIL')" 2>/dev/null | grep -q "OK" && \
        log_success "Redis is accessible" || { log_error "Redis not accessible"; ((failed++)); }

    if [ $failed -eq 0 ]; then
        log_success "All services verified!"
    else
        log_warn "$failed service(s) failed verification"
    fi
}

# =============================================================================
# Cleanup Functions
# =============================================================================

cleanup() {
    log_step "Cleanup"

    log_warn "This will delete all deployments in namespace: $NAMESPACE"
    read -p "Are you sure? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Cleanup cancelled."
        exit 0
    fi

    log_info "Deleting Helm releases..."
    helm uninstall airflow -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall "${RELEASE_PREFIX}-minio" -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall "${RELEASE_PREFIX}-redis" -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall "${RELEASE_PREFIX}-mlflow" -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall "${RELEASE_PREFIX}-monitoring" -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall postgresql -n "$NAMESPACE" 2>/dev/null || true

    log_info "Deleting migration jobs..."
    kubectl delete job airflow-db-migrate -n "$NAMESPACE" 2>/dev/null || true

    log_info "Deleting API manifests..."
    kubectl delete -k "$K8S_DIR" 2>/dev/null || true

    log_info "Deleting MinIO resources..."
    kubectl delete -f "$ROOT_DIR/minio/k8s/minio.yaml" -n "$NAMESPACE" 2>/dev/null || true

    log_info "Deleting secrets..."
    kubectl delete secret ml-pipeline-secrets -n "$NAMESPACE" 2>/dev/null || true

    read -p "Delete namespace $NAMESPACE? (yes/no): " delete_ns
    if [ "$delete_ns" == "yes" ]; then
        kubectl delete namespace "$NAMESPACE"
    fi

    log_success "Cleanup complete."
}

# =============================================================================
# Main
# =============================================================================

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deploy ML inference infrastructure on Kubernetes."
    echo ""
    echo "Options:"
    echo "  (no args)       Deploy everything (infrastructure + API)"
    echo "  --infra-only    Deploy infrastructure services only"
    echo "  --api-only      Deploy API only (requires infrastructure)"
    echo "  --status        Show deployment status"
    echo "  --endpoints     Show service access information"
    echo "  --verify        Verify service connectivity"
    echo "  --cleanup       Remove all deployments"
    echo "  --help          Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  NAMESPACE       Kubernetes namespace (default: ml-pipeline)"
    echo "  RELEASE_PREFIX  Helm release prefix (default: ml)"
    echo "  IMAGE_TAG       API image tag (default: 1.0.0)"
    echo ""
    echo "Examples:"
    echo "  $0                    # Full deployment"
    echo "  $0 --infra-only       # Deploy only infrastructure"
    echo "  $0 --status           # Check status"
    echo "  $0 --verify           # Verify connectivity"
    echo "  $0 --cleanup          # Remove everything"
}

main() {
    case "${1:-}" in
        --infra-only)
            check_prerequisites
            add_helm_repos
            create_namespace
            deploy_infrastructure
            show_status
            show_endpoints
            ;;
        --api-only)
            check_prerequisites
            create_namespace
            deploy_api
            show_status
            ;;
        --status)
            show_status
            ;;
        --endpoints)
            show_endpoints
            ;;
        --verify)
            verify_services
            ;;
        --cleanup)
            cleanup
            ;;
        --help|-h)
            usage
            ;;
        "")
            # Full deployment
            check_prerequisites
            add_helm_repos
            create_namespace
            deploy_infrastructure
            deploy_api
            show_status
            show_endpoints
            verify_services

            log_step "Deployment Complete!"
            echo -e "${GREEN}Your ML inference infrastructure is ready!${NC}"
            echo ""
            echo "Next steps:"
            echo "  1. Port-forward the API: kubectl port-forward -n $NAMESPACE svc/crypto-prediction-api 8000:8000"
            echo "  2. Test the API: curl http://localhost:8000/health"
            echo "  3. View API docs: http://localhost:8000/docs"
            echo "  4. Run validation: ./scripts/validate-deployment.sh --env k8s"
            echo ""
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"

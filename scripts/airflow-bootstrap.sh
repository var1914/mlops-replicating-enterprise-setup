#!/bin/bash
#
# =============================================================================
# Airflow Bootstrap Script for ML Pipeline
# =============================================================================
#
# This script deploys Apache Airflow on Kubernetes for the unified
# ETL + ML Training pipeline.
#
# Prerequisites:
#   - Kubernetes cluster running (e.g., Docker Desktop K8s)
#   - Helm 3.x installed
#   - kubectl configured
#   - Infrastructure deployed (MinIO, PostgreSQL, MLflow, Redis)
#
# DAGs included:
#   - etl_crypto_data_pipeline: Binance API -> MinIO -> PostgreSQL
#   - ml_training_pipeline: Features -> Training -> MLflow -> Inference API
#
# Usage:
#   ./scripts/airflow-bootstrap.sh              # Deploy Airflow
#   ./scripts/airflow-bootstrap.sh --build      # Build image and deploy
#   ./scripts/airflow-bootstrap.sh --upgrade    # Upgrade existing deployment
#   ./scripts/airflow-bootstrap.sh --status     # Show deployment status
#   ./scripts/airflow-bootstrap.sh --cleanup    # Remove Airflow deployment
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
RELEASE_NAME="${RELEASE_NAME:-airflow}"
IMAGE_TAG="${IMAGE_TAG:-0.0.5}"
LOCAL_REGISTRY="${LOCAL_REGISTRY:-localhost:5050}"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

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

# =============================================================================
# Prerequisites Check
# =============================================================================

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
        exit 1
    fi

    # Check namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_warn "Namespace '$NAMESPACE' does not exist."
        log_info "Creating namespace..."
        kubectl create namespace "$NAMESPACE"
    fi

    # Check infrastructure services
    log_info "Checking infrastructure services..."

    local infra_ok=true

    # Check PostgreSQL
    if kubectl get svc postgresql -n "$NAMESPACE" &> /dev/null; then
        log_success "PostgreSQL: Found"
    else
        log_warn "PostgreSQL: Not found in namespace $NAMESPACE"
        infra_ok=false
    fi

    # Check MinIO
    if kubectl get svc -l app.kubernetes.io/name=minio -n "$NAMESPACE" &> /dev/null 2>&1; then
        log_success "MinIO: Found"
    else
        log_warn "MinIO: Not found in namespace $NAMESPACE"
        infra_ok=false
    fi

    # Check MLflow
    if kubectl get svc -l app.kubernetes.io/name=mlflow -n "$NAMESPACE" &> /dev/null 2>&1; then
        log_success "MLflow: Found"
    else
        log_warn "MLflow: Not found in namespace $NAMESPACE"
        infra_ok=false
    fi

    if [ "$infra_ok" = false ]; then
        log_warn "Some infrastructure services are missing."
        log_info "Run ./scripts/k8s-bootstrap.sh --infra-only first."
        read -p "Continue anyway? (y/n): " continue_deploy
        if [ "$continue_deploy" != "y" ]; then
            exit 1
        fi
    fi

    log_success "Prerequisites check complete."
}

# =============================================================================
# Build Custom Airflow Image
# =============================================================================

build_image() {
    log_step "Building Custom Airflow Image"

    local image_name="${LOCAL_REGISTRY}/custom-airflow:${IMAGE_TAG}"

    log_info "Building image: $image_name"

    docker build \
        -t "$image_name" \
        -f "$ROOT_DIR/docker/Dockerfile.airflow" \
        "$ROOT_DIR"

    log_success "Image built: $image_name"

    # Check if local registry is running
    if docker ps | grep -q "registry:2"; then
        log_info "Pushing to local registry..."
        docker push "$image_name"
        log_success "Image pushed to $LOCAL_REGISTRY"
    else
        log_warn "Local registry not running. Image available locally only."
        log_info "For K8s deployment, start a local registry:"
        log_info "  docker run -d -p 5050:5000 --name registry registry:2"
    fi
}

# =============================================================================
# Add Helm Repository
# =============================================================================

add_helm_repo() {
    log_step "Adding Airflow Helm Repository"

    helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
    helm repo update

    log_success "Helm repositories updated."
}

# =============================================================================
# Deploy Airflow
# =============================================================================

deploy_airflow() {
    log_step "Deploying Apache Airflow"

    log_info "Release Name: $RELEASE_NAME"
    log_info "Namespace: $NAMESPACE"
    log_info "Image Tag: $IMAGE_TAG"

    # Deploy using Helm
    helm upgrade --install "$RELEASE_NAME" apache-airflow/airflow \
        --namespace "$NAMESPACE" \
        --values "$ROOT_DIR/airflow/values.yaml" \
        --set images.airflow.tag="$IMAGE_TAG" \
        --timeout 10m \
        --wait

    log_success "Airflow deployed successfully!"
}

# =============================================================================
# Wait for Airflow to be Ready
# =============================================================================

wait_for_airflow() {
    log_step "Waiting for Airflow Components"

    log_info "Waiting for webserver..."
    kubectl wait --for=condition=ready pod \
        -l component=webserver,release="$RELEASE_NAME" \
        -n "$NAMESPACE" \
        --timeout=300s 2>/dev/null || {
            log_warn "Webserver may not be ready yet. Check manually."
        }

    log_info "Waiting for scheduler..."
    kubectl wait --for=condition=ready pod \
        -l component=scheduler,release="$RELEASE_NAME" \
        -n "$NAMESPACE" \
        --timeout=300s 2>/dev/null || {
            log_warn "Scheduler may not be ready yet. Check manually."
        }

    log_success "Airflow components are ready!"
}

# =============================================================================
# Create Pools
# =============================================================================

create_pools() {
    log_step "Creating Airflow Pools"

    # Get webserver pod
    WEBSERVER_POD=$(kubectl get pod -n "$NAMESPACE" \
        -l component=webserver,release="$RELEASE_NAME" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$WEBSERVER_POD" ]; then
        log_warn "Could not find webserver pod. Skipping pool creation."
        return
    fi

    log_info "Creating pools via Airflow CLI..."

    # Create ML training pool
    kubectl exec -n "$NAMESPACE" "$WEBSERVER_POD" -- \
        airflow pools set ml_training_pool 3 "Pool for ML model training tasks" 2>/dev/null || true

    # Create data extraction pool
    kubectl exec -n "$NAMESPACE" "$WEBSERVER_POD" -- \
        airflow pools set data_extraction_pool 5 "Pool for API data extraction" 2>/dev/null || true

    # Create database operations pool
    kubectl exec -n "$NAMESPACE" "$WEBSERVER_POD" -- \
        airflow pools set db_operations_pool 4 "Pool for database loading operations" 2>/dev/null || true

    log_success "Pools created."
}

# =============================================================================
# Show Status
# =============================================================================

show_status() {
    log_step "Airflow Deployment Status"

    echo -e "${CYAN}Pods:${NC}"
    kubectl get pods -n "$NAMESPACE" -l release="$RELEASE_NAME" -o wide
    echo ""

    echo -e "${CYAN}Services:${NC}"
    kubectl get svc -n "$NAMESPACE" -l release="$RELEASE_NAME"
    echo ""

    echo -e "${CYAN}PVCs:${NC}"
    kubectl get pvc -n "$NAMESPACE" -l release="$RELEASE_NAME"
    echo ""

    # Get webserver URL
    WEBSERVER_SVC=$(kubectl get svc -n "$NAMESPACE" \
        -l component=webserver,release="$RELEASE_NAME" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -n "$WEBSERVER_SVC" ]; then
        echo -e "${CYAN}Access Airflow UI:${NC}"
        echo "  kubectl port-forward -n $NAMESPACE svc/$WEBSERVER_SVC 8080:8080"
        echo "  Then open: http://localhost:8080"
        echo "  Credentials: admin / admin123"
    fi
}

# =============================================================================
# Show DAGs Info
# =============================================================================

show_dags_info() {
    log_step "Available DAGs"

    echo "ETL Pipeline DAG: etl_crypto_data_pipeline"
    echo "  - Schedule: @hourly"
    echo "  - Stages: prechecks -> extraction -> loading"
    echo "  - Data flow: Binance API -> MinIO -> PostgreSQL"
    echo ""

    echo "ML Training DAG: ml_training_pipeline"
    echo "  - Schedule: 0 2 * * * (daily at 2 AM)"
    echo "  - Stages: validation -> features -> training -> promotion -> api_reload"
    echo "  - Data flow: PostgreSQL -> Features -> MLflow -> Inference API"
    echo ""

    echo "Trigger DAGs manually:"
    echo "  # Via Airflow UI:"
    echo "  kubectl port-forward -n $NAMESPACE svc/${RELEASE_NAME}-webserver 8080:8080"
    echo ""
    echo "  # Via CLI (from webserver pod):"
    echo "  kubectl exec -n $NAMESPACE -it \$(kubectl get pod -n $NAMESPACE -l component=webserver -o name | head -1) -- \\"
    echo "    airflow dags trigger etl_crypto_data_pipeline"
    echo ""
    echo "  # Via demo scripts:"
    echo "  ./scripts/demo-etl-pipeline.sh --airflow"
    echo "  ./scripts/demo-ml-pipeline.sh --airflow"
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    log_step "Cleanup Airflow Deployment"

    log_warn "This will remove the Airflow deployment."
    read -p "Are you sure? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Cleanup cancelled."
        exit 0
    fi

    log_info "Uninstalling Airflow Helm release..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true

    log_info "Removing PVCs..."
    kubectl delete pvc -l release="$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true

    log_success "Airflow cleanup complete."
}

# =============================================================================
# Usage
# =============================================================================

usage() {
    echo "Airflow Bootstrap Script for ML Pipeline"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no args)      Deploy Airflow (without building image)"
    echo "  --build        Build custom Airflow image and deploy"
    echo "  --upgrade      Upgrade existing Airflow deployment"
    echo "  --status       Show deployment status"
    echo "  --dags         Show available DAGs information"
    echo "  --cleanup      Remove Airflow deployment"
    echo "  --help         Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  NAMESPACE      Kubernetes namespace (default: ml-pipeline)"
    echo "  RELEASE_NAME   Helm release name (default: airflow)"
    echo "  IMAGE_TAG      Airflow image tag (default: 0.0.5)"
    echo "  LOCAL_REGISTRY Local Docker registry (default: localhost:5050)"
    echo ""
    echo "Examples:"
    echo "  $0                        # Deploy using existing image"
    echo "  $0 --build                # Build image and deploy"
    echo "  $0 --status               # Check status"
    echo "  IMAGE_TAG=0.0.6 $0 --build # Build with specific tag"
}

# =============================================================================
# Main
# =============================================================================

main() {
    case "${1:-}" in
        --build)
            check_prerequisites
            build_image
            add_helm_repo
            deploy_airflow
            wait_for_airflow
            create_pools
            show_status
            show_dags_info

            log_step "Deployment Complete!"
            log_success "Airflow is ready for ETL and ML pipelines!"
            ;;

        --upgrade)
            log_step "Upgrading Airflow"
            add_helm_repo
            deploy_airflow
            wait_for_airflow
            show_status
            ;;

        --status)
            show_status
            ;;

        --dags)
            show_dags_info
            ;;

        --cleanup)
            cleanup
            ;;

        --help|-h)
            usage
            ;;

        "")
            # Deploy without building
            check_prerequisites
            add_helm_repo
            deploy_airflow
            wait_for_airflow
            create_pools
            show_status
            show_dags_info

            log_step "Deployment Complete!"
            log_success "Airflow is ready for ETL and ML pipelines!"
            echo ""
            echo "Next Steps:"
            echo "  1. Access Airflow UI: kubectl port-forward -n $NAMESPACE svc/${RELEASE_NAME}-webserver 8080:8080"
            echo "  2. Open http://localhost:8080 (admin/admin123)"
            echo "  3. Trigger ETL DAG: etl_crypto_data_pipeline"
            echo "  4. Trigger ML DAG: ml_training_pipeline"
            echo ""
            echo "Or use demo scripts:"
            echo "  ./scripts/demo-etl-pipeline.sh"
            echo "  ./scripts/demo-ml-pipeline.sh"
            ;;

        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"

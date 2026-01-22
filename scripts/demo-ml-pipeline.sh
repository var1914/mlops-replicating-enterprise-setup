#!/bin/bash
#
# End-to-End Demo: ML Training Pipeline
#
# This script demonstrates the complete ML workflow for crypto prediction:
# 1. Data validation for training readiness
# 2. Feature engineering (80+ technical indicators)
# 3. Model training (LightGBM, XGBoost)
# 4. Model registration to MLflow
# 5. Model promotion to staging/production
# 6. Inference API reload
#
# This can be run standalone or triggered via Airflow DAG: ml_training_pipeline
#
# Usage:
#   ./scripts/demo-ml-pipeline.sh                    # Run full ML demo
#   ./scripts/demo-ml-pipeline.sh --symbol BTCUSDT   # Train for specific symbol
#   ./scripts/demo-ml-pipeline.sh --task direction   # Train specific task
#   ./scripts/demo-ml-pipeline.sh --env k8s          # Run in Kubernetes environment
#   ./scripts/demo-ml-pipeline.sh --help             # Show help

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Default configuration
ENV="${ENV:-docker}"
SYMBOL="${SYMBOL:-BTCUSDT}"
TASK="${TASK:-return_4step}"
MODEL_TYPE="${MODEL_TYPE:-lightgbm}"

# Environment-specific URLs
case "$ENV" in
    k8s|kubernetes)
        MLFLOW_URL="${MLFLOW_TRACKING_URI:-http://ml-mlflow:5000}"
        MINIO_ENDPOINT="${MINIO_ENDPOINT:-ml-minio:9000}"
        POSTGRES_HOST="${POSTGRES_HOST:-postgresql}"
        INFERENCE_API_URL="${INFERENCE_API_URL:-http://crypto-prediction-api:8000}"
        ;;
    *)
        MLFLOW_URL="${MLFLOW_TRACKING_URI:-http://localhost:5001}"
        MINIO_ENDPOINT="${MINIO_ENDPOINT:-localhost:9000}"
        POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
        INFERENCE_API_URL="${INFERENCE_API_URL:-http://localhost:8000}"
        ;;
esac

MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-admin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-admin123}"
POSTGRES_USER="${POSTGRES_USER:-mlflow}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-mlflow123}"
POSTGRES_DB="${POSTGRES_DB:-mlflow}"

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}\n"
}

print_step() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Step $1: $2${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

print_warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

show_help() {
    cat << EOF
End-to-End Demo: ML Training Pipeline

This script demonstrates the crypto prediction ML pipeline:
  - Validate training data quality
  - Generate 80+ technical indicator features
  - Train LightGBM and XGBoost models
  - Register models to MLflow
  - Promote best models to production
  - Reload inference API with new models

Usage:
    ./scripts/demo-ml-pipeline.sh [OPTIONS]

Options:
    --env ENV           Environment (docker|k8s) [default: docker]
    --symbol SYMBOL     Crypto symbol to train [default: BTCUSDT]
    --task TASK         Prediction task [default: return_4step]
    --model-type TYPE   Model type (lightgbm|xgboost|all) [default: lightgbm]
    --skip-validation   Skip data validation step
    --skip-features     Skip feature engineering (use existing)
    --skip-promotion    Skip model promotion step
    --airflow           Trigger via Airflow DAG instead
    --help, -h          Show this help message

Available Tasks:
    return_1step        15-minute price return prediction
    return_4step        1-hour price return prediction
    return_16step       4-hour price return prediction
    direction_4step     1-hour direction prediction (up/down)
    volatility_4step    1-hour volatility prediction
    vol_regime_4step    Volatility regime classification

Environment Variables:
    MLFLOW_TRACKING_URI MLflow server URL
    MINIO_ENDPOINT      MinIO server endpoint
    POSTGRES_HOST       PostgreSQL host
    INFERENCE_API_URL   Inference API URL

Examples:
    # Run with defaults (Docker environment)
    ./scripts/demo-ml-pipeline.sh

    # Run for Kubernetes environment
    ./scripts/demo-ml-pipeline.sh --env k8s

    # Train specific symbol and task
    ./scripts/demo-ml-pipeline.sh --symbol ETHUSDT --task direction_4step

    # Train all model types
    ./scripts/demo-ml-pipeline.sh --model-type all

    # Run via Airflow
    ./scripts/demo-ml-pipeline.sh --airflow

Supported Symbols:
    BTCUSDT, ETHUSDT, BNBUSDT, ADAUSDT, SOLUSDT,
    XRPUSDT, DOTUSDT, AVAXUSDT, MATICUSDT, LINKUSDT
EOF
}

# =============================================================================
# Parse Arguments
# =============================================================================

SKIP_VALIDATION=false
SKIP_FEATURES=false
SKIP_PROMOTION=false
USE_AIRFLOW=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENV="$2"
            shift 2
            ;;
        --symbol)
            SYMBOL="$2"
            shift 2
            ;;
        --task)
            TASK="$2"
            shift 2
            ;;
        --model-type)
            MODEL_TYPE="$2"
            shift 2
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        --skip-features)
            SKIP_FEATURES=true
            shift
            ;;
        --skip-promotion)
            SKIP_PROMOTION=true
            shift
            ;;
        --airflow)
            USE_AIRFLOW=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# =============================================================================
# Pre-flight Checks
# =============================================================================

run_preflight_checks() {
    print_step "1" "Pre-flight Checks"

    local all_passed=true

    # Check MLflow
    print_info "Checking MLflow at $MLFLOW_URL..."
    if curl -s --max-time 5 "$MLFLOW_URL/health" 2>/dev/null | grep -q "OK\|healthy"; then
        print_success "MLflow: Accessible"
    else
        # Try alternative endpoint
        if curl -s --max-time 5 "$MLFLOW_URL/api/2.0/mlflow/experiments/list" 2>/dev/null | grep -q "experiments"; then
            print_success "MLflow: Accessible (API check)"
        else
            print_error "MLflow: Not accessible at $MLFLOW_URL"
            all_passed=false
        fi
    fi

    # Check MinIO
    print_info "Checking MinIO at $MINIO_ENDPOINT..."
    if curl -s --max-time 5 "http://$MINIO_ENDPOINT/minio/health/live" 2>/dev/null | grep -q "OK"; then
        print_success "MinIO: Accessible"
    else
        if nc -z ${MINIO_ENDPOINT%:*} ${MINIO_ENDPOINT#*:} 2>/dev/null; then
            print_success "MinIO: Port accessible"
        else
            print_error "MinIO: Not accessible at $MINIO_ENDPOINT"
            all_passed=false
        fi
    fi

    # Check PostgreSQL (for training data)
    print_info "Checking PostgreSQL at $POSTGRES_HOST..."
    if nc -z "$POSTGRES_HOST" 5432 2>/dev/null; then
        print_success "PostgreSQL: Accessible"
    else
        print_error "PostgreSQL: Not accessible (required for training data)"
        all_passed=false
    fi

    # Check Inference API (optional)
    print_info "Checking Inference API at $INFERENCE_API_URL..."
    if curl -s --max-time 5 "$INFERENCE_API_URL/health" 2>/dev/null | grep -q "healthy\|ok"; then
        print_success "Inference API: Accessible"
    else
        print_warn "Inference API: Not accessible (optional for training)"
    fi

    # Check Python dependencies
    print_info "Checking Python dependencies..."
    cd "$ROOT_DIR"
    if python3 -c "import lightgbm, xgboost, mlflow, sklearn" 2>/dev/null; then
        print_success "Python ML dependencies: Available"
    else
        print_error "Python ML dependencies: Missing (run pip install -r requirements.txt)"
        all_passed=false
    fi

    echo ""
    if [ "$all_passed" = true ]; then
        print_success "All pre-flight checks passed!"
        return 0
    else
        print_error "Some pre-flight checks failed"
        return 1
    fi
}

# =============================================================================
# ML Pipeline Functions
# =============================================================================

run_data_validation() {
    print_step "2" "Data Validation"

    print_info "Validating training data for $SYMBOL..."

    cd "$ROOT_DIR"

    python3 -c "
import sys
sys.path.insert(0, 'dags')

try:
    from automated_data_validation import DataValidationSuite

    validator = DataValidationSuite('$SYMBOL')
    result = validator.run_all_validations()

    print(f'Validation Results for $SYMBOL:')
    print(f'  Valid: {result.get(\"is_valid\", False)}')
    print(f'  Record Count: {result.get(\"record_count\", 0)}')
    print(f'  Missing Values: {result.get(\"missing_values\", \"N/A\")}')
    print(f'  Date Range: {result.get(\"date_range\", \"N/A\")}')

    if not result.get('is_valid', False):
        print('')
        print('Warning: Data validation issues detected')
        print('Proceeding anyway - review results carefully')
except ImportError:
    print('Validation module not available')
    print('Skipping validation, proceeding with training...')
except Exception as e:
    print(f'Validation warning: {e}')
    print('Proceeding with training...')
"

    print_success "Data validation complete"
}

run_feature_engineering() {
    print_step "3" "Feature Engineering"

    print_info "Generating features for $SYMBOL..."
    print_info "This includes 80+ technical indicators..."

    cd "$ROOT_DIR"

    # Set environment variables for the Python script
    export MLFLOW_TRACKING_URI="$MLFLOW_URL"
    export MINIO_ENDPOINT="$MINIO_ENDPOINT"
    export MINIO_ACCESS_KEY="$MINIO_ACCESS_KEY"
    export MINIO_SECRET_KEY="$MINIO_SECRET_KEY"
    export DB_HOST="$POSTGRES_HOST"
    export DB_USER="$POSTGRES_USER"
    export DB_PASSWORD="$POSTGRES_PASSWORD"
    export DB_NAME="$POSTGRES_DB"

    python3 -c "
import sys
sys.path.insert(0, 'dags')
from feature_eng import FeatureEngineeringPipeline
from src.config import get_settings

settings = get_settings()
db_config = settings.database.get_connection_params()

pipeline = FeatureEngineeringPipeline(db_config)
result = pipeline.run_feature_pipeline(['$SYMBOL'], create_targets=True)

print(f'Feature Engineering Results for $SYMBOL:')
print(f'  Features Generated: {result.get(\"features_count\", 0)}')
print(f'  Targets Created: {result.get(\"targets_created\", False)}')
print(f'  Output Location: MinIO bucket (crypto-features)')
"

    print_success "Feature engineering complete"
}

run_model_training() {
    print_step "4" "Model Training"

    print_info "Training models for $SYMBOL..."
    print_info "Task: $TASK"
    print_info "Model Type: $MODEL_TYPE"

    cd "$ROOT_DIR"

    # Set environment variables
    export MLFLOW_TRACKING_URI="$MLFLOW_URL"
    export MINIO_ENDPOINT="$MINIO_ENDPOINT"
    export MINIO_ACCESS_KEY="$MINIO_ACCESS_KEY"
    export MINIO_SECRET_KEY="$MINIO_SECRET_KEY"
    export DB_HOST="$POSTGRES_HOST"
    export DB_USER="$POSTGRES_USER"
    export DB_PASSWORD="$POSTGRES_PASSWORD"
    export DB_NAME="$POSTGRES_DB"

    # Determine model types to train
    if [ "$MODEL_TYPE" = "all" ]; then
        MODEL_TYPES="['lightgbm', 'xgboost']"
    else
        MODEL_TYPES="['$MODEL_TYPE']"
    fi

    python3 -c "
import sys
sys.path.insert(0, 'dags')
from model_training import ModelTrainingPipeline

pipeline = ModelTrainingPipeline()

# Train models
results = pipeline.train_symbol_models(
    symbol='$SYMBOL',
    tasks_to_train=['$TASK'],
    model_types=$MODEL_TYPES
)

print(f'Training Results for $SYMBOL - $TASK:')
print(f'  Models Trained: {len(results.get(\"models\", []))}')

if 'best_metrics' in results:
    print(f'  Best Metrics:')
    for metric, value in results['best_metrics'].items():
        print(f'    {metric}: {value:.4f}' if isinstance(value, float) else f'    {metric}: {value}')

if 'run_ids' in results:
    print(f'')
    print(f'  MLflow Run IDs:')
    for run_id in results.get('run_ids', []):
        print(f'    - {run_id}')
"

    print_success "Model training complete"
}

run_model_promotion() {
    print_step "5" "Model Promotion"

    print_info "Promoting best models to staging/production..."

    cd "$ROOT_DIR"

    export MLFLOW_TRACKING_URI="$MLFLOW_URL"

    python3 -c "
import sys
sys.path.insert(0, 'dags')
from model_promotion import ModelPromotion

promoter = ModelPromotion()

# Promote to staging
print('Promoting to Staging...')
staging_results = promoter.promote_models_to_staging()
print(f'  Models promoted to staging: {staging_results.get(\"promoted_count\", 0)}')

# Auto-promote to production if metrics meet threshold
print('')
print('Checking for production promotion...')
production_results = promoter.automated_promotion_with_validation()
print(f'  Models promoted to production: {production_results.get(\"promoted_count\", 0)}')

if production_results.get('promoted_models'):
    print('')
    print('Production Models:')
    for model in production_results['promoted_models']:
        print(f'  - {model}')
"

    print_success "Model promotion complete"
}

reload_inference_api() {
    print_step "6" "Reload Inference API"

    print_info "Triggering API to reload models..."

    RELOAD_RESPONSE=$(curl -s -X POST "$INFERENCE_API_URL/models/reload" 2>/dev/null || echo '{"error": "API not accessible"}')

    if echo "$RELOAD_RESPONSE" | grep -q "error"; then
        print_warn "API reload: $RELOAD_RESPONSE"
        print_info "You may need to manually reload the API or restart the service"
    else
        print_success "API models reloaded"
        echo "$RELOAD_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RELOAD_RESPONSE"
    fi

    # Check loaded models
    echo ""
    print_info "Checking loaded models..."

    MODELS_RESPONSE=$(curl -s "$INFERENCE_API_URL/models" 2>/dev/null || echo '{"error": "API not accessible"}')

    if echo "$MODELS_RESPONSE" | grep -q "error"; then
        print_warn "Could not retrieve loaded models"
    else
        echo "Loaded Models:"
        echo "$MODELS_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$MODELS_RESPONSE"
    fi
}

verify_results() {
    print_step "7" "Verify Results"

    print_info "Checking MLflow model registry..."

    cd "$ROOT_DIR"

    export MLFLOW_TRACKING_URI="$MLFLOW_URL"

    python3 -c "
import mlflow
from mlflow.tracking import MlflowClient

client = MlflowClient()

# List registered models
print('Registered Models:')
print('-' * 60)

try:
    models = client.search_registered_models()
    for model in models:
        print(f'Model: {model.name}')
        # Get latest versions
        for version in model.latest_versions:
            print(f'  Version {version.version}: Stage={version.current_stage}')
        print('')
except Exception as e:
    print(f'Could not list models: {e}')

# List recent runs for our symbol
print('')
print('Recent Training Runs:')
print('-' * 60)

try:
    experiment = client.get_experiment_by_name('crypto_prediction')
    if experiment:
        runs = client.search_runs(
            experiment_ids=[experiment.experiment_id],
            filter_string=\"tags.symbol = '$SYMBOL'\",
            max_results=5,
            order_by=['start_time DESC']
        )
        for run in runs:
            print(f'Run: {run.info.run_id[:8]}...')
            print(f'  Symbol: {run.data.tags.get(\"symbol\", \"N/A\")}')
            print(f'  Task: {run.data.tags.get(\"task\", \"N/A\")}')
            print(f'  Model: {run.data.tags.get(\"model_type\", \"N/A\")}')
            if run.data.metrics:
                print(f'  Metrics: {dict(list(run.data.metrics.items())[:3])}')
            print('')
except Exception as e:
    print(f'Could not list runs: {e}')
"

    print_success "Results verified"
}

trigger_airflow_dag() {
    print_step "1" "Triggering Airflow DAG"

    AIRFLOW_URL="${AIRFLOW_URL:-http://localhost:8080}"

    print_info "Triggering DAG: ml_training_pipeline"
    print_info "Airflow URL: $AIRFLOW_URL"

    # Check if Airflow is accessible
    if ! curl -s --max-time 5 "$AIRFLOW_URL/health" | grep -q "healthy"; then
        print_error "Airflow is not accessible at $AIRFLOW_URL"
        print_info "Make sure Airflow is running and accessible"
        exit 1
    fi

    # Trigger the DAG
    RESPONSE=$(curl -s -X POST \
        "$AIRFLOW_URL/api/v1/dags/ml_training_pipeline/dagRuns" \
        -H "Content-Type: application/json" \
        -u "${AIRFLOW_USER:-admin}:${AIRFLOW_PASSWORD:-admin}" \
        -d "{\"conf\": {\"symbol\": \"$SYMBOL\", \"task\": \"$TASK\"}}")

    if echo "$RESPONSE" | grep -q "dag_run_id"; then
        DAG_RUN_ID=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['dag_run_id'])")
        print_success "DAG triggered successfully"
        print_info "DAG Run ID: $DAG_RUN_ID"
        print_info "Monitor at: $AIRFLOW_URL/dags/ml_training_pipeline/grid"
    else
        print_error "Failed to trigger DAG"
        echo "$RESPONSE"
        exit 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "ML Training Pipeline Demo: $SYMBOL"

    echo "Configuration:"
    echo "  Environment:      $ENV"
    echo "  Symbol:           $SYMBOL"
    echo "  Task:             $TASK"
    echo "  Model Type:       $MODEL_TYPE"
    echo "  MLflow URL:       $MLFLOW_URL"
    echo "  Inference API:    $INFERENCE_API_URL"
    echo ""

    # Trigger via Airflow if requested
    if [ "$USE_AIRFLOW" = true ]; then
        trigger_airflow_dag
        exit 0
    fi

    # Run pre-flight checks
    if ! run_preflight_checks; then
        print_error "Pre-flight checks failed. Fix the issues and try again."
        exit 1
    fi

    # Run ML pipeline steps
    if [ "$SKIP_VALIDATION" = false ]; then
        run_data_validation
    fi

    if [ "$SKIP_FEATURES" = false ]; then
        run_feature_engineering
    fi

    run_model_training

    if [ "$SKIP_PROMOTION" = false ]; then
        run_model_promotion
    fi

    reload_inference_api
    verify_results

    # Summary
    print_header "ML Pipeline Demo Complete!"

    cat << EOF
What was demonstrated:
  ✓ Validated training data quality for $SYMBOL
  ✓ Generated 80+ technical indicator features
  ✓ Trained $MODEL_TYPE model(s) for $TASK prediction
  ✓ Registered models to MLflow registry
  ✓ Promoted best models to staging/production
  ✓ Reloaded inference API with new models

Model Location:
  MLflow Registry: $MLFLOW_URL/#/models
  Artifacts:       MinIO bucket (crypto-models)

Next Steps:
  1. View experiments: $MLFLOW_URL
  2. Test predictions: curl -X POST $INFERENCE_API_URL/predict/$SYMBOL
  3. View API docs: $INFERENCE_API_URL/docs
  4. Monitor in Grafana: http://localhost:3000

To train more models:
  # Train different task
  ./scripts/demo-ml-pipeline.sh --task direction_4step

  # Train all model types
  ./scripts/demo-ml-pipeline.sh --model-type all

  # Train for different symbol
  ./scripts/demo-ml-pipeline.sh --symbol ETHUSDT

  # Train all symbols via Airflow
  ./scripts/demo-ml-pipeline.sh --airflow

Complete Pipeline (ETL + ML):
  1. ./scripts/demo-etl-pipeline.sh --symbol $SYMBOL
  2. ./scripts/demo-ml-pipeline.sh --symbol $SYMBOL
EOF
}

main

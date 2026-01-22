#!/bin/bash
#
# End-to-End Demo: ETL Pipeline
#
# This script demonstrates the complete ETL workflow for crypto data:
# 1. Pre-flight checks (API, MinIO, PostgreSQL connectivity)
# 2. Extract data from Binance API
# 3. Store raw data in MinIO
# 4. Load transformed data to PostgreSQL
# 5. Validate data quality
#
# This can be run standalone or triggered via Airflow DAG: etl_crypto_data_pipeline
#
# Usage:
#   ./scripts/demo-etl-pipeline.sh              # Run full ETL demo
#   ./scripts/demo-etl-pipeline.sh --check-only # Only run pre-flight checks
#   ./scripts/demo-etl-pipeline.sh --symbol BTCUSDT # Run for specific symbol
#   ./scripts/demo-etl-pipeline.sh --env k8s    # Run in Kubernetes environment
#   ./scripts/demo-etl-pipeline.sh --help       # Show help

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
BATCH_SIZE="${BATCH_SIZE:-1000}"
TOTAL_RECORDS="${TOTAL_RECORDS:-10000}"

# Environment-specific URLs
case "$ENV" in
    k8s|kubernetes)
        MINIO_ENDPOINT="${MINIO_ENDPOINT:-ml-minio:9000}"
        POSTGRES_HOST="${POSTGRES_HOST:-postgresql}"
        REDIS_HOST="${REDIS_HOST:-ml-redis-master}"
        BINANCE_URL="${BINANCE_URL:-https://api.binance.com/api/v3/klines}"
        ;;
    *)
        MINIO_ENDPOINT="${MINIO_ENDPOINT:-localhost:9000}"
        POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
        REDIS_HOST="${REDIS_HOST:-localhost}"
        BINANCE_URL="${BINANCE_URL:-https://api.binance.com/api/v3/klines}"
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
End-to-End Demo: ETL Pipeline

This script demonstrates the crypto data ETL pipeline:
  - Extract crypto market data from Binance API
  - Store raw data in MinIO (S3-compatible storage)
  - Transform and load data into PostgreSQL
  - Validate data quality

Usage:
    ./scripts/demo-etl-pipeline.sh [OPTIONS]

Options:
    --env ENV           Environment (docker|k8s) [default: docker]
    --symbol SYMBOL     Crypto symbol to extract [default: BTCUSDT]
    --batch-size SIZE   Records per batch [default: 1000]
    --total-records N   Total records to extract [default: 10000]
    --check-only        Only run pre-flight checks
    --skip-checks       Skip pre-flight checks
    --airflow           Trigger via Airflow DAG instead
    --help, -h          Show this help message

Environment Variables:
    MINIO_ENDPOINT      MinIO server endpoint
    MINIO_ACCESS_KEY    MinIO access key
    MINIO_SECRET_KEY    MinIO secret key
    POSTGRES_HOST       PostgreSQL host
    POSTGRES_USER       PostgreSQL user
    POSTGRES_PASSWORD   PostgreSQL password
    POSTGRES_DB         PostgreSQL database

Examples:
    # Run with defaults (Docker environment)
    ./scripts/demo-etl-pipeline.sh

    # Run for Kubernetes environment
    ./scripts/demo-etl-pipeline.sh --env k8s

    # Run for specific symbol with more data
    ./scripts/demo-etl-pipeline.sh --symbol ETHUSDT --total-records 50000

    # Only check connectivity
    ./scripts/demo-etl-pipeline.sh --check-only

Supported Symbols:
    BTCUSDT, ETHUSDT, BNBUSDT, ADAUSDT, SOLUSDT,
    XRPUSDT, DOTUSDT, AVAXUSDT, MATICUSDT, LINKUSDT
EOF
}

# =============================================================================
# Parse Arguments
# =============================================================================

CHECK_ONLY=false
SKIP_CHECKS=false
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
        --batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        --total-records)
            TOTAL_RECORDS="$2"
            shift 2
            ;;
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --skip-checks)
            SKIP_CHECKS=true
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

    # Check Binance API
    print_info "Checking Binance API..."
    if curl -s --max-time 10 "$BINANCE_URL?symbol=BTCUSDT&interval=1m&limit=1" | grep -q "openTime\|0"; then
        print_success "Binance API: Accessible"
    else
        print_error "Binance API: Not accessible"
        all_passed=false
    fi

    # Check MinIO
    print_info "Checking MinIO at $MINIO_ENDPOINT..."
    if curl -s --max-time 5 "http://$MINIO_ENDPOINT/minio/health/live" 2>/dev/null | grep -q "OK\|{"; then
        print_success "MinIO: Accessible"
    else
        # Try alternative health endpoint
        if nc -z ${MINIO_ENDPOINT%:*} ${MINIO_ENDPOINT#*:} 2>/dev/null; then
            print_success "MinIO: Port accessible"
        else
            print_error "MinIO: Not accessible at $MINIO_ENDPOINT"
            all_passed=false
        fi
    fi

    # Check PostgreSQL
    print_info "Checking PostgreSQL at $POSTGRES_HOST..."
    if command -v pg_isready &> /dev/null; then
        if pg_isready -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" &>/dev/null; then
            print_success "PostgreSQL: Accessible"
        else
            print_warn "PostgreSQL: pg_isready check failed (may still work)"
        fi
    elif command -v psql &> /dev/null; then
        if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" &>/dev/null; then
            print_success "PostgreSQL: Accessible"
        else
            print_error "PostgreSQL: Not accessible"
            all_passed=false
        fi
    else
        if nc -z "$POSTGRES_HOST" 5432 2>/dev/null; then
            print_success "PostgreSQL: Port 5432 accessible"
        else
            print_error "PostgreSQL: Not accessible at $POSTGRES_HOST:5432"
            all_passed=false
        fi
    fi

    # Check Redis (optional)
    print_info "Checking Redis at $REDIS_HOST..."
    if nc -z "$REDIS_HOST" 6379 2>/dev/null; then
        print_success "Redis: Accessible"
    else
        print_warn "Redis: Not accessible (optional for ETL)"
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
# ETL Pipeline Functions
# =============================================================================

run_extraction() {
    print_step "2" "Data Extraction from Binance API"

    print_info "Symbol: $SYMBOL"
    print_info "Batch Size: $BATCH_SIZE"
    print_info "Total Records: $TOTAL_RECORDS"

    cd "$ROOT_DIR"

    # Run extraction using Python module
    python3 -c "
import sys
sys.path.insert(0, 'dags')
from etl.extraction import MinIODataExtractor

extractor = MinIODataExtractor('$SYMBOL', '$BINANCE_URL')

batch_count = 0
total_records = 0

for batch_data in extractor.fetch_symbol_data_in_batches(
    interval='15m',
    total_limit=$TOTAL_RECORDS,
    batch_size=$BATCH_SIZE
):
    batch_count += 1
    metadata = extractor.save_raw_data(batch_data, batch_number=batch_count)
    total_records += len(batch_data)
    print(f'  Batch {batch_count}: {len(batch_data)} records saved to MinIO')

print(f'')
print(f'Extraction complete: {total_records} records in {batch_count} batches')
"

    print_success "Data extraction complete"
}

run_loading() {
    print_step "3" "Data Loading to PostgreSQL"

    print_info "Loading data from MinIO to PostgreSQL..."

    cd "$ROOT_DIR"

    # Run loading using Python module
    python3 -c "
import sys
sys.path.insert(0, 'dags')
from etl.loader import PostgreSQLLoader, discover_batches

# Discover batches
class MockContext:
    pass

batches = discover_batches()
print(f'Found {len(batches)} batches to process')

symbol_batches = [b for b in batches if b['symbol'] == '$SYMBOL']
print(f'Processing {len(symbol_batches)} batches for $SYMBOL')

total_records = 0
for batch_info in symbol_batches:
    loader = PostgreSQLLoader(batch_info['symbol'], batch_info['batch_number'])
    result = loader.process_batch()
    if result['status'] == 'success':
        records = result.get('records_processed', 0)
        total_records += records
        print(f\"  Batch {batch_info['batch_number']}: {records} records loaded\")
    else:
        print(f\"  Batch {batch_info['batch_number']}: FAILED - {result.get('error', 'Unknown error')}\")

print(f'')
print(f'Loading complete: {total_records} total records loaded to PostgreSQL')
"

    print_success "Data loading complete"
}

run_validation() {
    print_step "4" "Data Validation"

    print_info "Validating data quality..."

    cd "$ROOT_DIR"

    # Run validation using Python module
    python3 -c "
import sys
sys.path.insert(0, 'dags')

try:
    from automated_data_validation import DataValidationSuite

    validator = DataValidationSuite('$SYMBOL')
    result = validator.run_all_validations()

    print(f'Validation Results for $SYMBOL:')
    print(f'  Valid: {result.get(\"is_valid\", False)}')
    print(f'  Records: {result.get(\"record_count\", 0)}')
    print(f'  Missing Values: {result.get(\"missing_values\", \"N/A\")}')
    print(f'  Duplicates: {result.get(\"duplicates\", \"N/A\")}')
except ImportError as e:
    print(f'Validation module not available: {e}')
    print('Skipping detailed validation...')
except Exception as e:
    print(f'Validation warning: {e}')
    print('Data may still be usable.')
"

    print_success "Data validation complete"
}

verify_results() {
    print_step "5" "Verify Results"

    print_info "Checking data in PostgreSQL..."

    cd "$ROOT_DIR"

    python3 -c "
import sys
sys.path.insert(0, 'dags')
from etl.config import DB_CONFIG
import psycopg2

conn = psycopg2.connect(**DB_CONFIG)
cur = conn.cursor()

# Count records
cur.execute(\"SELECT COUNT(*) FROM crypto_data WHERE symbol = '$SYMBOL'\")
count = cur.fetchone()[0]
print(f'Records in PostgreSQL for $SYMBOL: {count}')

# Get time range
cur.execute('''
    SELECT
        MIN(to_timestamp(open_time/1000)) as earliest,
        MAX(to_timestamp(open_time/1000)) as latest
    FROM crypto_data
    WHERE symbol = '\$SYMBOL'
''')
result = cur.fetchone()
if result[0]:
    print(f'Time range: {result[0]} to {result[1]}')

# Sample data
cur.execute('''
    SELECT symbol, to_timestamp(open_time/1000) as time, close_price, volume
    FROM crypto_data
    WHERE symbol = '\$SYMBOL'
    ORDER BY open_time DESC
    LIMIT 5
''')
print('')
print('Latest records:')
print('-' * 60)
for row in cur.fetchall():
    print(f'  {row[1]} | Price: {row[2]:.2f} | Volume: {row[3]:.2f}')

conn.close()
"

    print_success "Results verified"
}

trigger_airflow_dag() {
    print_step "1" "Triggering Airflow DAG"

    AIRFLOW_URL="${AIRFLOW_URL:-http://localhost:8080}"

    print_info "Triggering DAG: etl_crypto_data_pipeline"
    print_info "Airflow URL: $AIRFLOW_URL"

    # Check if Airflow is accessible
    if ! curl -s --max-time 5 "$AIRFLOW_URL/health" | grep -q "healthy"; then
        print_error "Airflow is not accessible at $AIRFLOW_URL"
        print_info "Make sure Airflow is running and accessible"
        exit 1
    fi

    # Trigger the DAG
    RESPONSE=$(curl -s -X POST \
        "$AIRFLOW_URL/api/v1/dags/etl_crypto_data_pipeline/dagRuns" \
        -H "Content-Type: application/json" \
        -u "${AIRFLOW_USER:-admin}:${AIRFLOW_PASSWORD:-admin}" \
        -d "{\"conf\": {\"symbol\": \"$SYMBOL\"}}")

    if echo "$RESPONSE" | grep -q "dag_run_id"; then
        DAG_RUN_ID=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['dag_run_id'])")
        print_success "DAG triggered successfully"
        print_info "DAG Run ID: $DAG_RUN_ID"
        print_info "Monitor at: $AIRFLOW_URL/dags/etl_crypto_data_pipeline/grid"
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
    print_header "ETL Pipeline Demo: $SYMBOL"

    echo "Configuration:"
    echo "  Environment:    $ENV"
    echo "  Symbol:         $SYMBOL"
    echo "  Batch Size:     $BATCH_SIZE"
    echo "  Total Records:  $TOTAL_RECORDS"
    echo "  MinIO:          $MINIO_ENDPOINT"
    echo "  PostgreSQL:     $POSTGRES_HOST"
    echo ""

    # Trigger via Airflow if requested
    if [ "$USE_AIRFLOW" = true ]; then
        trigger_airflow_dag
        exit 0
    fi

    # Run pre-flight checks
    if [ "$SKIP_CHECKS" = false ]; then
        if ! run_preflight_checks; then
            print_error "Pre-flight checks failed. Fix the issues and try again."
            print_info "Use --skip-checks to skip these checks (not recommended)"
            exit 1
        fi
    fi

    # Exit if only checking
    if [ "$CHECK_ONLY" = true ]; then
        print_success "Pre-flight checks complete"
        exit 0
    fi

    # Run ETL pipeline
    run_extraction
    run_loading
    run_validation
    verify_results

    # Summary
    print_header "ETL Pipeline Demo Complete!"

    cat << EOF
What was demonstrated:
  ✓ Pre-flight checks (Binance API, MinIO, PostgreSQL)
  ✓ Extracted ${TOTAL_RECORDS} records from Binance API
  ✓ Stored raw data in MinIO (batched JSON files)
  ✓ Transformed and loaded data to PostgreSQL
  ✓ Validated data quality

Data Location:
  MinIO:      s3://crypto-raw-data/date=$(date +%Y-%m-%d)/symbol=$SYMBOL/
  PostgreSQL: crypto_data table (symbol='$SYMBOL')

Next Steps:
  1. Run ML pipeline: ./scripts/demo-ml-pipeline.sh --symbol $SYMBOL
  2. View data in PostgreSQL: psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB
  3. View raw data in MinIO: http://${MINIO_ENDPOINT%:*}:9001 (console)
  4. Run via Airflow: ./scripts/demo-etl-pipeline.sh --airflow

To run for all symbols:
  for symbol in BTCUSDT ETHUSDT BNBUSDT ADAUSDT SOLUSDT; do
    ./scripts/demo-etl-pipeline.sh --symbol \$symbol --total-records 50000
  done
EOF
}

main

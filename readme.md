# ML Engineering Platform with MLOps

**Complete ML platform: ETL → Features → Training → Serving → Monitoring**

[![Docker](https://img.shields.io/badge/Docker-Ready-blue)](https://www.docker.com/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-Ready-326CE5)](https://kubernetes.io/)
[![Airflow](https://img.shields.io/badge/Airflow-3.0-017CEE)](https://airflow.apache.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **Production-ready ML platform** with unified ETL and ML pipelines orchestrated by Apache Airflow 3.0 on Kubernetes.

---

## 🎯 What Is This?

A complete ML engineering platform that provides end-to-end infrastructure:

**Current Status:**

| Component | Status | Notes |
|-----------|--------|-------|
| **ETL Pipeline** | ✅ **FULLY TESTED** | 2.25M records loaded, verified end-to-end |
| **ML Training Pipeline** | ⏳ **Testing Pending** | DAG deployed, infrastructure ready |
| **Infrastructure** | ✅ **PRODUCTION READY** | All 18 pods running on K8s |

**What's Working Now:**
- ✅ **ETL Pipeline** - Binance API → MinIO → PostgreSQL (**2.25M records loaded, verified**)
- ✅ **Kubernetes Deployment** - Fully tested on Docker Desktop K8s (ARM64/Apple Silicon)
- ✅ **Apache Airflow 3.0** - Unified orchestration with KubernetesExecutor
- ✅ **Model Registry** (MLflow) - Version control and stage-based deployment
- ✅ **Monitoring** (Prometheus + Grafana) - Metrics and dashboards
- ⏳ **ML Training Pipeline** - DAG deployed, ready for testing (Features → Training → MLflow)
- ⏳ **Inference API** (FastAPI) - Ready for deployment after ML training

**Pipeline Architecture:**
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Apache Airflow (Orchestration)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ETL Pipeline (etl_crypto_data_pipeline)                                    │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │ Binance  │───▶│  MinIO   │───▶│Transform │───▶│PostgreSQL│              │
│  │   API    │    │  (Raw)   │    │  (ETL)   │    │ (Crypto) │              │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘              │
│                                                         │                   │
│  ML Pipeline (ml_training_pipeline)                     ▼                   │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │ Feature  │───▶│  Model   │───▶│  MLflow  │───▶│Inference │              │
│  │   Eng    │    │ Training │    │ Registry │    │   API    │              │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘              │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start (Kubernetes - Recommended)

### Prerequisites

- **Docker Desktop** with Kubernetes enabled (Settings → Kubernetes → Enable Kubernetes)
- **kubectl**: `brew install kubectl`
- **Helm**: `brew install helm`
- Minimum resources: 8GB RAM, 4 CPUs

### One-Command Deployment

```bash
# Clone repository
git clone <repo-url>
cd ml-eng-with-ops

# Deploy infrastructure (PostgreSQL, MinIO, Redis, MLflow, Prometheus, Grafana, Airflow)
# DAGs are baked into Airflow image - ready to trigger after deployment
./scripts/k8s-bootstrap.sh --infra-only
```

**What gets deployed** (5-10 minutes):
- MinIO (S3-compatible storage for raw data and artifacts)
- Redis (caching layer)
- PostgreSQL (2 databases: `crypto` for ETL data, `airflow` for metadata)
- MLflow (experiment tracking and model registry)
- Prometheus + Grafana (monitoring stack)
- Apache Airflow 3.0 (orchestration with KubernetesExecutor)

### Access Services

Port-forward to access the UIs:

```bash
# Airflow UI
kubectl port-forward -n ml-pipeline svc/airflow-api-server 8080:8080
# Open: http://localhost:8080 (admin / admin123)

# MinIO Console
kubectl port-forward -n ml-pipeline svc/minio 9000:9000 9001:9001
# Open: http://localhost:9001 (admin / admin123)

# MLflow UI
kubectl port-forward -n ml-pipeline svc/ml-mlflow 5000:5000
# Open: http://localhost:5000

# Grafana
kubectl port-forward -n ml-pipeline svc/ml-monitoring-grafana 3000:80
# Open: http://localhost:3000 (admin / prom-operator)
```

### Run ETL Pipeline (Load 2.25M Records)

> **✅ TESTED AND VERIFIED** - This pipeline has been fully tested and loads ~2.25M crypto records

**Option A: Via Airflow UI (Recommended)**

1. **Port forward Airflow API**:
   ```bash
   kubectl port-forward -n ml-pipeline svc/airflow-api-server 8080:8080
   ```

2. **Open Airflow UI**:
   - URL: http://localhost:8080
   - Login: `admin` / `admin123`

3. **Enable and Trigger DAG**:
   - Find the `etl_crypto_data_pipeline` DAG
   - Toggle it to "On" (if paused)
   - Click the play button (▶) to trigger manually

4. **Monitor Execution**:
   - Watch task progress in the Grid view
   - All 10 symbols extract in parallel
   - Total time: ~15-20 minutes

**Option B: Via CLI**
```bash
# Trigger ETL pipeline
kubectl exec -n ml-pipeline deployment/airflow-scheduler -- \
  airflow dags trigger etl_crypto_data_pipeline

# Monitor running pods
kubectl get pods -n ml-pipeline | grep etl
```

**5. Verify Data Loaded**:
```bash
# Check record counts per symbol
kubectl exec -n ml-pipeline postgresql-0 -- \
  psql -U postgres -d crypto -c "SELECT symbol, COUNT(*) FROM crypto_data GROUP BY symbol;"

# Check total records
kubectl exec -n ml-pipeline postgresql-0 -- \
  psql -U postgres -d crypto -c "SELECT COUNT(*) as total_records FROM crypto_data;"
```

**Expected Results**:
```
   symbol    | count
-------------+--------
 BTCUSDT    | 250000
 ETHUSDT    | 250000
 BNBUSDT    | 250000
 SOLUSDT    | 250000
 ADAUSDT    | 250000
 XRPUSDT    | 250000
 DOTUSDT    | 250000
 AVAXUSDT   | 186728  (less historical data on Binance)
 MATICUSDT  | 250000
 LINKUSDT   | 250000
-------------+--------
Total: ~2.25 million records
```

**What the ETL Pipeline Does**:
- **Extraction**: Fetches OHLCV data from Binance API (`/api/v3/klines`)
  - 10 cryptocurrency symbols
  - 15-minute interval candles
  - Up to 250,000 records per symbol (configurable in [dags/etl/config.py](dags/etl/config.py))
  - Pagination with 1000 records per batch
  - Rate limiting and retry logic

- **Storage**: Saves raw JSON to MinIO
  - Bucket: `crypto-raw-data`
  - Structure: `date=YYYY-MM-DD/symbol=SYMBOL/batch_XXX.json`
  - Includes metadata: batch_id, record count, extraction time

- **Loading**: Transforms and loads to PostgreSQL
  - Calculates buy ratio: `(taker_buy_volume / total_volume) * 100`
  - Bulk insert with upsert logic: `ON CONFLICT (symbol, open_time) DO UPDATE`
  - Indexes on symbol, open_time for query performance

---

## ⚙️ Apache Airflow 3.0 Configuration

### Key Architecture Decisions

**Executor**: KubernetesExecutor
- Each task runs in a separate Kubernetes pod
- Automatic scaling based on task concurrency
- Pods are deleted after task completion (saves resources)

**DAG Deployment**: Baked into Custom Docker Image
- DAGs are included in the Docker image at build time
- No need for DAG persistence volumes
- Faster deployment and consistent across all pods
- **Critical**: Must disable `dags.persistence.enabled: false` in [airflow/values.yaml](airflow/values.yaml#L43-L45)

**Database Migrations**: Separate Kubernetes Job
- Migrations run BEFORE Helm deployment in a dedicated Job
- **Critical**: Must disable `waitForMigrations.enabled: false` for all components
- Prevents init container timeouts
- Located in [scripts/k8s-bootstrap.sh](scripts/k8s-bootstrap.sh#L358-L393)

**Custom Airflow Image**: [docker/Dockerfile.airflow](docker/Dockerfile.airflow)
```dockerfile
FROM apache/airflow:3.0.2-python3.12

USER airflow
RUN pip install --no-cache-dir \
    psycopg2-binary minio boto3 pandas numpy pyarrow \
    scikit-learn lightgbm xgboost mlflow requests redis \
    prometheus-client matplotlib seaborn plotly joblib \
    pydantic pydantic-settings

COPY --chown=airflow:root dags/ /opt/airflow/dags/
COPY --chown=airflow:root src/ /opt/airflow/src/
ENV PYTHONPATH="/opt/airflow/src:/opt/airflow/dags"
```

Build and push:
```bash
docker build -t localhost:5050/custom-airflow:0.0.8 -f docker/Dockerfile.airflow .
docker push localhost:5050/custom-airflow:0.0.8
```

### Environment Variables

Configured in [airflow/values.yaml](airflow/values.yaml#L93-L123):
```yaml
env:
  - name: PYTHONPATH
    value: /opt/airflow/src:/opt/airflow/dags
  - name: MLFLOW_TRACKING_URI
    value: http://ml-mlflow:5000
  - name: MINIO_ENDPOINT
    value: minio:9000
  - name: MINIO_ACCESS_KEY
    value: admin
  - name: MINIO_SECRET_KEY
    value: admin123
  - name: DB_HOST
    value: postgresql
  - name: DB_PORT
    value: "5432"
  - name: DB_USER
    value: crypto
  - name: DB_PASSWORD
    value: crypto123
  - name: DB_NAME
    value: crypto
  - name: REDIS_HOST
    value: ml-redis-master
  - name: REDIS_PORT
    value: "6379"
  - name: REDIS_PASSWORD
    value: redis123
```

### Known Limitations

#### 1. Log Persistence
- **Issue**: Logs are not persisted after worker pod deletion
- **Reason**: Docker Desktop's `local-path` provisioner doesn't support `ReadWriteMany` volumes
- **Workaround (Dev)**: View logs while task is running
- **Solution (Prod)**: Configure remote logging to S3/GCS

#### 2. Some Symbols Have Less Data
- **Issue**: AVAXUSDT has only 186,728 records instead of 250,000
- **Reason**: Limited historical data availability on Binance
- **Impact**: This is expected behavior, not a bug

#### 3. Local Registry for Custom Images
- **Issue**: Uses `localhost:5050` Docker registry
- **Reason**: Simplifies local development on Docker Desktop
- **Limitation**: Not suitable for multi-node clusters
- **Solution (Prod)**: Use cloud container registry (ECR, GCR, ACR)

---

## 🔄 Unified ETL + ML Pipelines (Airflow)

The platform includes two Airflow DAGs that work together for complete ML automation:

### ETL Pipeline: `etl_crypto_data_pipeline`

Extracts crypto data from Binance API and loads to PostgreSQL.

```bash
# Run ETL demo (standalone)
./scripts/demo-etl-pipeline.sh --symbol BTCUSDT

# Run via Airflow
./scripts/demo-etl-pipeline.sh --airflow
```

**DAG Stages:**
1. **Pre-checks** - Validate Binance API, MinIO, PostgreSQL connectivity
2. **Extraction** - Fetch data from Binance API (10 symbols, ~3M records)
3. **Loading** - Transform and load to PostgreSQL with upsert

**Schedule:** `@hourly`

### ML Training Pipeline: `ml_training_pipeline`

> **⏳ STATUS: Testing Pending** - DAG deployed and infrastructure ready

Trains models on crypto data and deploys to production.

```bash
# Trigger via Airflow CLI
kubectl exec -n ml-pipeline deployment/airflow-scheduler -- \
  airflow dags trigger ml_training_pipeline

# Or via Airflow UI: http://localhost:8080
# Enable and trigger 'ml_training_pipeline' DAG
```

**DAG Stages:**
1. **Data Validation** - Check data quality for training readiness
2. **Feature Engineering** - Generate 80+ technical indicators (parallel per symbol)
3. **Model Training** - Train LightGBM and XGBoost models (uses `ml_training_pool`)
4. **Model Promotion** - Promote best models to staging/production

**Schedule:** `0 2 * * *` (Daily at 2 AM, after ETL completes)

**Prerequisites:**
- ETL pipeline must run first (to populate `crypto_data` table)
- Create ML training pool: `kubectl exec -n ml-pipeline deployment/airflow-scheduler -- airflow pools set ml_training_pool 3 "ML training pool"`

**Expected Output:**
- 60 models trained (10 symbols × 3 tasks × 2 algorithms)
- Models registered in MLflow with metrics
- Best models promoted to staging

### Deploy Airflow on Kubernetes

```bash
# Deploy complete infrastructure first
./scripts/k8s-bootstrap.sh

# Deploy Airflow with custom image
./scripts/airflow-bootstrap.sh --build

# Access Airflow UI
kubectl port-forward -n ml-pipeline svc/airflow-webserver 8080:8080
# Open http://localhost:8080 (admin/admin123)
```

### Supported Crypto Symbols

`BTCUSDT`, `ETHUSDT`, `BNBUSDT`, `ADAUSDT`, `SOLUSDT`, `XRPUSDT`, `DOTUSDT`, `AVAXUSDT`, `MATICUSDT`, `LINKUSDT`

---

## 🎬 Try It Yourself: E2E Demo

Want to see the full workflow in action? Run our demo script that automatically:
1. Creates a sample ML model (sklearn or HuggingFace)
2. Registers it to MLflow with artifacts in MinIO
3. Promotes to Production stage
4. Triggers API to reload models
5. Makes inference requests
6. Shows Prometheus metrics

### Run the Demo (Docker Compose)

```bash
# Make sure services are running
docker-compose up -d

# Install dependencies (first time only)
pip install mlflow scikit-learn requests minio

# Run the E2E demo
python3 scripts/demo-e2e-workflow.py
```

### Demo Options

```bash
# Default: sklearn model with Docker Compose endpoints
python3 scripts/demo-e2e-workflow.py

# Use a HuggingFace model instead
python3 scripts/demo-e2e-workflow.py --use-huggingface

# Skip model registration (just test inference & metrics)
python3 scripts/demo-e2e-workflow.py --skip-model-registration

# Custom number of inference requests
python3 scripts/demo-e2e-workflow.py --num-requests 20
```

### View Results

After running the demo:
- **MLflow UI**: http://localhost:5001 - See registered model and experiment
- **Grafana Dashboard**: http://localhost:3000 → Dashboards → ML Pipeline → ML Inference API Dashboard
- **API Docs**: http://localhost:8000/docs - Try the endpoints yourself

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://localhost:3000 | admin / admin |
| MLflow | http://localhost:5001 | (no auth) |
| MinIO Console | http://localhost:9001 | admin / admin123 |
| API Docs | http://localhost:8000/docs | (no auth) |
| Prometheus | http://localhost:9090 | (no auth) |

---

## 🏢 Adapt for Your Business Use Case

This boilerplate works for **any ML problem**. We provide ready-to-use examples and templates.

### Quick Start with Sample Data

```bash
cd examples/generic-ml-usecase

# Generate sample data and train a model
./run_demo.sh demand_forecasting    # E-commerce demand prediction
./run_demo.sh churn_prediction      # Customer churn classification
./run_demo.sh fraud_detection       # Transaction fraud detection
./run_demo.sh price_optimization    # Dynamic pricing
```

### Train on Your Own Data

```bash
# 1. Prepare your CSV/Parquet data file

# 2. Train and register model
python examples/generic-ml-usecase/train_model.py \
    --data your_data.csv \
    --target target_column \
    --task regression \
    --model-name your_model_name \
    --promote

# 3. Reload API to serve new model
curl -X POST http://localhost:8000/models/reload
```

### Supported Use Cases

| Industry | Use Cases | Task Type |
|----------|-----------|-----------|
| **E-commerce** | Demand forecasting, price optimization, recommendations | Regression |
| **Finance** | Fraud detection, credit scoring, churn prediction | Classification |
| **Healthcare** | Patient outcomes, resource allocation | Both |
| **Marketing** | Lead scoring, campaign optimization, CLV | Both |
| **Operations** | Predictive maintenance, inventory optimization | Both |

### What's Included

```
examples/generic-ml-usecase/
├── data_generator.py      # Generate sample datasets
├── train_model.py         # Generic model training script
├── run_demo.sh            # E2E demo runner
└── ADAPTATION_GUIDE.md    # Detailed customization guide
```

**For detailed instructions, see [Adaptation Guide](examples/generic-ml-usecase/ADAPTATION_GUIDE.md)**

---

## 🏭 Production Recommendations

Based on lessons learned from deployment and troubleshooting:

### High Availability

**Database**:
- Use managed PostgreSQL (AWS RDS, GCP Cloud SQL, Azure Database)
- Enable automated backups and point-in-time recovery
- Configure read replicas for query-heavy workloads
- Use connection pooling (PgBouncer)

**Redis**:
- Use managed Redis (AWS ElastiCache, GCP Memorystore, Azure Cache)
- Enable Redis Cluster mode for horizontal scaling
- Configure persistence (AOF + RDB)

**Object Storage**:
- Replace MinIO with cloud object storage (S3, GCS, Azure Blob)
- Enable versioning for data protection
- Configure lifecycle policies for cost optimization
- Use bucket replication for disaster recovery

### Logging & Monitoring

**Remote Logging** (Critical for KubernetesExecutor):
```yaml
# airflow/values.yaml
config:
  logging:
    remote_logging: "True"
    remote_base_log_folder: "s3://your-airflow-logs-bucket/"
    remote_log_conn_id: "aws_default"
    encrypt_s3_logs: "True"
```

**Prometheus Metrics**:
- Configure remote write to long-term storage (Cortex, Thanos, or cloud provider)
- Set up alerting rules for critical metrics:
  - DAG failure rate
  - Task execution time (SLOs)
  - Database connection pool exhaustion
  - MinIO/S3 request errors

**Log Aggregation**:
- Use Elasticsearch + Kibana or cloud logging (CloudWatch, Stackdriver)
- Configure structured logging (JSON format)
- Set retention policies

### Security

**Secrets Management**:
```bash
# Use Kubernetes secrets or external secret managers
kubectl create secret generic airflow-secrets \
  --from-literal=postgres-password=<strong-password> \
  --from-literal=redis-password=<strong-password> \
  -n ml-pipeline

# Or use AWS Secrets Manager, GCP Secret Manager, Azure Key Vault
```

**Network Security**:
- Configure Network Policies to restrict pod-to-pod communication
- Use TLS for all inter-service communication
- Enable TLS for PostgreSQL, Redis, and MLflow
- Configure Ingress with TLS certificates (Let's Encrypt)

**Access Control**:
- Enable Airflow RBAC with LDAP/OAuth integration
- Configure MLflow authentication (e.g., basic auth, OAuth)
- Use Kubernetes RBAC for pod access
- Rotate credentials regularly

### Scaling

**Airflow Workers** (KubernetesExecutor):
```yaml
# airflow/values.yaml
config:
  kubernetes:
    worker_pods_creation_batch_size: 16
    multi_namespace_mode: True  # Scale across multiple namespaces
```

**Resource Limits**:
```yaml
# Set appropriate requests and limits
scheduler:
  resources:
    requests:
      cpu: 1000m
      memory: 2Gi
    limits:
      cpu: 2000m
      memory: 4Gi

workers:
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 4Gi
```

**Database Connection Pooling**:
```yaml
# airflow/values.yaml
config:
  core:
    sql_alchemy_pool_size: 20
    sql_alchemy_max_overflow: 40
    sql_alchemy_pool_recycle: 1800
```

### Deployment Best Practices

**Container Registry**:
- Use private cloud registry (ECR, GCR, ACR)
- Implement image scanning for vulnerabilities
- Use image signing and verification
- Tag images with git commit SHA for traceability

**CI/CD Pipeline**:
1. Build custom Airflow image on every commit
2. Run DAG validation tests (syntax, imports)
3. Deploy to staging environment
4. Run integration tests
5. Promote to production with approval

**GitOps Workflow**:
- Store Helm values and Kubernetes manifests in Git
- Use ArgoCD or FluxCD for declarative deployment
- Implement PR-based review process for configuration changes
- Enable automatic sync for dev, manual for production

**Disaster Recovery**:
- Backup Airflow metadata database daily
- Backup MinIO/S3 data with versioning
- Document restore procedures
- Test recovery process quarterly
- Maintain runbooks for common failure scenarios

### Cost Optimization

**Resource Management**:
- Set appropriate resource requests and limits
- Use cluster autoscaler to scale nodes
- Implement pod priority and preemption
- Use spot/preemptible instances for non-critical workloads

**Storage Optimization**:
- Configure lifecycle policies for old data
- Use cheaper storage tiers for infrequently accessed data
- Compress data before storing in MinIO/S3
- Delete old Airflow logs (retention policy)

---

## 📦 Production Deployment (Kubernetes)

> **✅ TESTED:** Docker Desktop Kubernetes (ARM64/Apple Silicon)

### One-Command Deployment

```bash
# Deploy complete infrastructure
./scripts/k8s-bootstrap.sh --infra-only

# Check deployment status
./scripts/k8s-bootstrap.sh --status
```

**Infrastructure Deployed**:

| Component | Purpose | Details |
|-----------|---------|---------|
| **PostgreSQL** | Databases | `crypto` (ETL data), `airflow` (metadata) |
| **MinIO** | Object Storage | S3-compatible, buckets: `crypto-raw-data`, `crypto-features`, `mlflow-artifacts` |
| **Redis** | Caching | Feature caching for ML inference |
| **MLflow** | ML Platform | Experiment tracking, model registry |
| **Airflow 3.0** | Orchestration | ETL + ML pipelines, KubernetesExecutor |
| **Prometheus** | Metrics | Time-series database for monitoring |
| **Grafana** | Visualization | Dashboards and alerting |

### Access Services

```bash
# API
kubectl port-forward -n ml-pipeline svc/crypto-prediction-api 8000:8000
curl http://localhost:8000/health

# MLflow UI
kubectl port-forward -n ml-pipeline svc/ml-mlflow 5000:5000
open http://localhost:5000

# Grafana
kubectl port-forward -n ml-pipeline svc/ml-monitoring-grafana 3000:80
open http://localhost:3000  # admin / prom-operator
```

### Cleanup

```bash
./scripts/k8s-bootstrap.sh --cleanup
```

### Run E2E Demo on Kubernetes

```bash
# First, port-forward the services
kubectl port-forward -n ml-pipeline svc/ml-mlflow 5000:5000 &
kubectl port-forward -n ml-pipeline svc/crypto-prediction-api 8000:8000 &
kubectl port-forward -n ml-pipeline svc/ml-minio 9000:9000 &

# Run demo with K8s endpoints
python3 scripts/demo-e2e-workflow.py \
    --mlflow-url http://localhost:5000 \
    --api-url http://localhost:8000 \
    --minio-endpoint localhost:9000
```

**For detailed Kubernetes deployment guide, see [k8s/README.md](k8s/README.md)**

### Production Features Included

| Feature | What It Does |
|---------|--------------|
| **Auto-scaling** | HPA scales 2-10 pods based on CPU (70%) / Memory (80%) |
| **Health Probes** | Liveness, readiness, startup probes configured |
| **Rolling Updates** | Zero-downtime deployments |
| **Resource Limits** | CPU: 500m-2000m, Memory: 1Gi-4Gi |
| **Monitoring** | Prometheus + Grafana with ServiceMonitor |
| **Security** | Non-root user, secrets management |

---

## 🔧 What's Included in This Boilerplate

### Infrastructure Components

**Docker Compose Setup** (`docker-compose.yml`) - **Local testing only**
- PostgreSQL - Data storage
- Redis - Feature caching
- MinIO - S3-compatible model storage
- MLflow - Model registry and tracking
- Inference API - FastAPI prediction service
- Prometheus - Metrics collection
- Grafana - Visualization dashboards

**Kubernetes Manifests** (`k8s/`) - **Production deployment**
- `api-deployment.yaml` - Deployment with health probes, resource limits
- `api-service.yaml` - ClusterIP service for load balancing
- `api-hpa.yaml` - HorizontalPodAutoscaler (2-10 replicas)
- `api-ingress.yaml` - External access with SSL/TLS
- `api-configmap.yaml` - Configuration management
- `api-servicemonitor.yaml` - Prometheus integration
- `secrets.yaml.example` - Secrets template
- `kustomization.yaml` - Kustomize configuration

**Docker Images** (`docker/`)
- `Dockerfile.inference` - Production API image
  - Multi-stage build for smaller size
  - Non-root user for security
  - Health checks built-in

### Application Code

**Inference API** (`app/production_api.py`)
- FastAPI with automatic OpenAPI docs
- Multi-model serving (load multiple models per task)
- Ensemble predictions (combine predictions from multiple models)
- Health/readiness/liveness endpoints for K8s
- Prometheus metrics export
- Hot model reloading (no downtime)
- Batch predictions support
- Error handling and logging

**Feature Pipeline** (`dags/`)
- `inference_feature_pipeline.py` - Real-time feature generation
- `feature_eng.py` - Feature engineering functions
- Supports multiple task types: regression, binary classification, multi-class classification

**Configuration** (`src/config/`)
- Pydantic-based settings with validation
- Environment variable support
- Type-safe configuration
- Multiple environments (.env.development, .env.production)

### Monitoring & Observability

**Prometheus Metrics** (Built-in)
- HTTP request count/latency by endpoint
- Prediction count/latency per task
- Loaded models count per symbol/task
- System metrics (CPU, memory, GC)
- Custom business metrics

**Grafana Dashboards** (`monitoring/grafana/`)
- API performance overview
- Model serving statistics
- Resource utilization
- Error rates and alerts

**Health Endpoints**
- `/health` - Detailed status with model information
- `/live` - Kubernetes liveness probe (process running)
- `/ready` - Kubernetes readiness probe (models loaded, ready to serve)
- `/metrics` - Prometheus metrics endpoint

---

## 📊 API Endpoints Reference

### Prediction Endpoints
- `POST /predict/{symbol}` - Single symbol, all tasks
- `POST /predict/batch` - Batch predictions for multiple symbols
- `GET /predict/{symbol}/task/{task}` - Single task for a symbol
- `GET /predict/{symbol}/summary` - Key predictions summary

### Model Management
- `GET /models` - List all loaded models with metadata
- `POST /models/reload` - Hot reload models from MLflow (no downtime)
- `POST /models/promote` - Promote model to Production/Staging stage

### Health & Monitoring
- `GET /health` - Detailed health with model status
- `GET /live` - Liveness probe (K8s)
- `GET /ready` - Readiness probe (K8s)
- `GET /metrics` - Prometheus metrics
- `GET /tasks` - List all available prediction tasks

### Debugging
- `GET /features/{symbol}` - View current feature values for debugging

### Interactive API Docs
- Visit `/docs` for Swagger UI
- Visit `/redoc` for ReDoc interface

---

## 🎨 Customizing for Your Use Case

This boilerplate includes a cryptocurrency prediction example, but works for any ML problem.

### Supported Use Cases

**Classification:**
- Customer churn prediction
- Fraud detection
- Sentiment analysis
- Image classification
- Spam detection

**Regression:**
- Demand forecasting
- Price prediction
- Sales forecasting
- Resource usage prediction

**Time Series:**
- Stock/crypto prediction
- Sensor data forecasting
- Energy consumption
- Traffic prediction

**Other:**
- Recommendation systems
- Anomaly detection
- Multi-task learning

### Customization Steps

1. **Define Your Tasks** - Edit `dags/inference_feature_pipeline.py`:
   ```python
   INFERENCE_TASKS = {
       'your_task': {
           'type': 'regression',  # or 'classification_binary', 'classification_multi'
           'description': 'What this predicts'
       }
   }
   ```

2. **Customize Features** - Edit `dags/feature_eng.py`:
   ```python
   def engineer_features(df):
       # Your domain-specific features
       return df
   ```

3. **Update Naming Convention** - Change model naming pattern to match your domain
   - Current: `crypto_{model_type}_{task}_{symbol}`
   - Your pattern: `{your_prefix}_{model_type}_{task}_{entity}`

4. **Configure Data Source** - Update `.env.development` or `k8s/api-configmap.yaml`

5. **Infrastructure remains the same** - No changes needed to API, K8s, monitoring!

---

## 🔮 Roadmap

### What's Working Now
- ✅ **ETL Pipeline** - Binance API → MinIO → PostgreSQL (2.25M records, tested)
- ✅ **Apache Airflow 3.0** - KubernetesExecutor with custom image
- ✅ **Infrastructure** - PostgreSQL, MinIO, Redis, MLflow, Prometheus, Grafana
- ✅ **Monitoring** - Prometheus metrics + Grafana dashboards
- ✅ **Model Registry** - MLflow with stage-based deployment

### In Progress
- ⏳ **ML Training Pipeline** - DAG deployed, testing pending
  - Feature engineering (80+ indicators)
  - LightGBM + XGBoost training
  - Model promotion to MLflow
  - Data validation framework

### Coming Soon

**Inference API Deployment**
- FastAPI prediction service
- Load models from MLflow
- Real-time feature generation
- Auto-scaling with HPA

**Authentication & Security**
- JWT/OAuth2 authentication
- API key management
- Rate limiting per client
- Request signing

**Advanced ML Capabilities**
- A/B testing framework
- Shadow deployments (test new models without affecting prod)
- Feature store integration (Feast)
- Model drift detection (Evidently AI)
- Online learning support

**Developer Experience**
- Automated testing (pytest + CI/CD)
- Pre-commit hooks (linting, formatting)
- GitHub Actions workflows
- Dev container support

**Production Features**
- Batch prediction jobs
- Distributed tracing (OpenTelemetry)
- Advanced monitoring (SLIs, SLOs, alerting)
- Canary releases
- Automatic rollback on errors

**Infrastructure**
- Terraform modules (AWS, GCP, Azure)
- Helm charts for easier K8s deployment
- Multi-cloud templates
- Service mesh integration (Istio)

---

## 🐛 Troubleshooting

### Airflow 3.0 Deployment Issues

#### 1. API Server Error: "invalid choice: 'api-server'"

**Symptom**: API server pod crashes with:
```
airflow command error: argument GROUP_OR_COMMAND: invalid choice: 'api-server'
/home/airflow/.local/lib/python3.9/site-packages/airflow/metrics/statsd_logger.py:184
```

**Root Cause**: Wrong Airflow version deployed (2.x instead of 3.0)

**Fix**:
1. Ensure Helm chart version is `1.18.0`:
   ```bash
   helm upgrade --install airflow apache-airflow/airflow \
     --namespace ml-pipeline \
     --values airflow/values.yaml \
     --version 1.18.0 \
     --wait --timeout 10m
   ```

2. Rebuild custom Airflow image with `--no-cache`:
   ```bash
   docker build --no-cache -t localhost:5050/custom-airflow:0.0.6 \
     -f docker/Dockerfile.airflow .
   docker push localhost:5050/custom-airflow:0.0.6
   ```

3. Verify `imagePullPolicy: Always` in migration job
4. Check pod logs show Python 3.12 (not 3.9)

#### 2. DAGs Not Visible in Airflow UI

**Symptom**: UI shows "No Dags found" but `kubectl exec -n ml-pipeline deployment/airflow-scheduler -- airflow dags list` shows them

**Root Cause**: DAG persistence PVC mounting empty volume over baked-in DAGs from Docker image

**Fix**: Disable DAG persistence in [airflow/values.yaml](airflow/values.yaml#L43-L45):
```yaml
dags:
  persistence:
    enabled: false  # DAGs are baked into custom Docker image
```

Then redeploy:
```bash
./scripts/k8s-bootstrap.sh --infra-only
```

#### 3. Worker Pods Failing with "DAG not found"

**Symptom**: Worker pods crash with:
```json
{"level":"error","event":"DAG not found during start up","dag_id":"etl_crypto_data_pipeline"}
```

**Root Cause**: Same as #2 - DAG persistence volume mounting over baked-in DAGs

**Fix**: Same as #2 - disable DAG persistence

#### 4. Database Schema Mismatch

**Symptom**:
```
Database error during bulk insert: column "trades_count" of relation "crypto_data" does not exist
LINE 4: close_price, volume, quote_volume, trades_count,...
```

**Root Cause**: Old table schema had `num_trades` instead of `trades_count`

**Fix**: Drop and recreate table with correct schema:
```bash
# Drop old table
kubectl exec -n ml-pipeline postgresql-0 -- \
  psql -U postgres -d crypto -c "DROP TABLE IF EXISTS crypto_data CASCADE;"

# Redeploy (script will recreate with correct schema)
./scripts/k8s-bootstrap.sh --infra-only
```

The correct schema (from [dags/etl/loader.py](dags/etl/loader.py#L156-L176)):
```sql
CREATE TABLE crypto_data (
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
    trades_count INTEGER NOT NULL,  -- NOT num_trades
    buy_ratio REAL,
    batch_id TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(symbol, open_time)
);
```

#### 5. Airflow UI Session Errors

**Symptom**: UI shows database session errors or login fails

**Root Cause**: Missing `session` table for Flask-Session

**Fix**: Create session table manually:
```bash
kubectl exec -n ml-pipeline postgresql-0 -- \
  psql -U postgres -d airflow -c "
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
"

# Restart API server
kubectl rollout restart deployment/airflow-api-server -n ml-pipeline
```

#### 6. Logs Not Accessible After Pod Deletion

**Symptom**:
```
Could not read served logs: HTTPConnectionPool(host='etl-crypto-data-pipeline-...', port=8793):
Max retries exceeded with url: /log/...
```

**Root Cause**: KubernetesExecutor deletes worker pods after completion, and logs persistence is disabled

**Known Limitation**: Docker Desktop's `local-path` provisioner doesn't support `ReadWriteMany` volumes required for shared log storage

**Workarounds**:

1. **Development**: Accept that logs are not persisted (view logs while pod is running)
   ```bash
   # View logs while task is running
   kubectl logs -n ml-pipeline <worker-pod-name> --follow
   ```

2. **Production**: Configure remote logging to S3/GCS in [airflow/values.yaml](airflow/values.yaml#L88-L90):
   ```yaml
   config:
     logging:
       remote_logging: "True"
       remote_base_log_folder: "s3://your-bucket/airflow-logs/"
       remote_log_conn_id: "aws_default"
   ```

#### 7. Migration Timeout Issues

**Symptom**: Airflow pods stuck in init containers waiting for migrations

**Root Cause**: `waitForMigrations.enabled: true` but migration job hasn't completed

**Fix**: Disable for ALL components in [airflow/values.yaml](airflow/values.yaml):
```yaml
webserver:
  waitForMigrations:
    enabled: false

scheduler:
  waitForMigrations:
    enabled: false

triggerer:
  waitForMigrations:
    enabled: false

dagProcessor:
  waitForMigrations:
    enabled: false

apiServer:
  waitForMigrations:
    enabled: false
```

Migrations run in a separate Kubernetes Job BEFORE Helm deployment (handled by [scripts/k8s-bootstrap.sh](scripts/k8s-bootstrap.sh#L358-L393)).

#### 8. MinIO Connection Issues

**Symptom**: ETL tasks fail with MinIO connection errors

**Root Cause**: Wrong MinIO endpoint in configuration

**Fix**: Ensure [dags/etl/config.py](dags/etl/config.py#L27) uses correct service name:
```python
MINIO_CONFIG = {
    'endpoint': os.getenv('MINIO_ENDPOINT', 'minio:9000'),  # NOT 'ml-minio:9000'
    'access_key': os.getenv('MINIO_ACCESS_KEY', 'admin'),
    'secret_key': os.getenv('MINIO_SECRET_KEY', 'admin123'),
    'secure': False
}
```

Verify MinIO service name:
```bash
kubectl get svc -n ml-pipeline | grep minio
```

### General Debugging Commands

```bash
# Check all pods status
kubectl get pods -n ml-pipeline

# View detailed pod information
kubectl describe pod -n ml-pipeline <pod-name>

# View pod logs
kubectl logs -n ml-pipeline <pod-name> --follow

# Check Airflow scheduler logs
kubectl logs -n ml-pipeline deployment/airflow-scheduler --follow

# Check Airflow worker logs (while running)
kubectl logs -n ml-pipeline <worker-pod-name> --follow

# Execute Airflow CLI commands
kubectl exec -n ml-pipeline deployment/airflow-scheduler -- \
  airflow dags list

kubectl exec -n ml-pipeline deployment/airflow-scheduler -- \
  airflow tasks list etl_crypto_data_pipeline

# Check PostgreSQL data
kubectl exec -n ml-pipeline postgresql-0 -- \
  psql -U postgres -d crypto -c "SELECT COUNT(*) FROM crypto_data;"

kubectl exec -n ml-pipeline postgresql-0 -- \
  psql -U postgres -d crypto -c "SELECT symbol, COUNT(*) FROM crypto_data GROUP BY symbol;"

# Check MinIO buckets
kubectl run minio-check --rm -i --restart=Never -n ml-pipeline \
  --image=minio/mc:latest \
  --command -- /bin/sh -c "
    mc alias set myminio http://minio:9000 admin admin123 && \
    mc ls myminio/
  "

# Check Helm release status
helm status airflow -n ml-pipeline
helm status postgresql -n ml-pipeline

# View deployment status
kubectl rollout status deployment/airflow-scheduler -n ml-pipeline
```

### API Issues (Inference Service)

#### API Returns 503 "No models loaded"

**Cause**: API is waiting for models to be registered and promoted to Production stage.

**Solution:**
1. Register model in MLflow: `mlflow.sklearn.log_model(model, "model", registered_model_name="...")`
2. Promote to "Production" stage in MLflow UI or programmatically
3. Reload API: `curl -X POST http://localhost:8000/models/reload`
4. Verify: `curl http://localhost:8000/models`

### Port Conflicts (Docker Compose)

**Problem:** Port 5001 or 8000 already in use

**Solution:** Edit `docker-compose.yml`:
```yaml
ports:
  - "8001:8000"  # Use different host port
```

### Services Not Starting (Docker Compose)

```bash
# Check logs
docker-compose logs api
docker-compose logs mlflow

# Restart specific service
docker-compose restart api

# Rebuild and restart
docker-compose up -d --build api
```

### Memory Issues (Docker Compose)

**Problem:** Services crash with OOM errors

**Solution:** Increase Docker memory:
- Docker Desktop → Settings → Resources → Memory (6-8GB recommended)

### Model Not Loading

**Problem:** Model registered but not loaded by API

**Check:**
1. Model naming convention: `crypto_{model_type}_{task}_{symbol}`
   - ✅ Correct: `crypto_lightgbm_return_1step_BTCUSDT`
   - ❌ Wrong: `my_model_v1`
2. Model stage: Must be "Production" or "Staging"
3. API logs: `docker-compose logs api` or `kubectl logs -n ml-pipeline -l app=crypto-prediction-api`

### Kubernetes Pod CrashLoopBackOff

**Check:**
```bash
# View pod status
kubectl get pods -n ml-pipeline

# Check logs
kubectl logs -n ml-pipeline <pod-name>

# Describe pod for events
kubectl describe pod -n ml-pipeline <pod-name>

# Common issues:
# 1. Missing secrets - check k8s/secrets.yaml
# 2. Wrong MLflow URI - check k8s/api-configmap.yaml
# 3. Network connectivity - check external services
```

### HPA Not Scaling

**Check:**
```bash
# View HPA status
kubectl get hpa -n ml-pipeline

# Check metrics server is installed
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml

# View current metrics
kubectl top pods -n ml-pipeline
```

---

## 📁 Project Structure

```
ml-eng-with-ops/
├── airflow/
│   └── values.yaml                    # Airflow Helm configuration
│                                      # Critical settings: dags.persistence.enabled=false,
│                                      # waitForMigrations.enabled=false
│
├── dags/
│   ├── airflow_dags/                  # Airflow DAG definitions
│   │   ├── etl_pipeline.py            # ETL DAG: Binance API → MinIO → PostgreSQL
│   │   └── ml_training_pipeline.py    # ML DAG: Features → Training → MLflow
│   │
│   └── etl/                           # ETL modules (imported by DAGs)
│       ├── config.py                  # Configuration (symbols, Binance API, MinIO, DB)
│       ├── extraction.py              # Data extraction from Binance API
│       └── loader.py                  # Data loading to PostgreSQL
│
├── docker/
│   ├── Dockerfile.airflow             # Custom Airflow 3.0 image
│   │                                  # Base: apache/airflow:3.0.2-python3.12
│   │                                  # Includes: DAGs, ETL modules, ML libraries
│   └── Dockerfile.inference           # Inference API image (FastAPI)
│
├── scripts/
│   ├── k8s-bootstrap.sh               # Main deployment script (idempotent)
│   │                                  # Deploys: PostgreSQL, MinIO, Redis, MLflow,
│   │                                  # Prometheus, Grafana, Airflow 3.0
│   ├── demo-etl-pipeline.sh           # ETL pipeline demo
│   └── demo-ml-pipeline.sh            # ML pipeline demo
│
├── minio/
│   └── k8s/
│       └── minio.yaml                 # MinIO Kubernetes manifest
│                                      # Creates buckets: crypto-raw-data, crypto-features,
│                                      # mlflow-artifacts
│
├── postgresql/
│   └── values.yaml                    # PostgreSQL Helm configuration
│                                      # Creates databases: crypto, airflow
│
├── redis/
│   └── values.yaml                    # Redis Helm configuration
│
├── mlflow/
│   └── values.yaml                    # MLflow Helm configuration
│
├── grafana/
│   └── values.yaml                    # Prometheus + Grafana Helm configuration
│
├── src/                               # Python modules (shared utilities)
│   ├── config/
│   │   └── settings.py                # Pydantic settings
│   └── ...
│
├── k8s/                               # Inference API Kubernetes manifests
│   ├── api-deployment.yaml
│   ├── api-service.yaml
│   ├── api-hpa.yaml
│   └── ...
│
├── monitoring/
│   ├── prometheus.yml
│   └── grafana/
│       └── dashboards/                # Grafana dashboard JSON files
│
├── README.md                          # This file (comprehensive documentation)
├── TROUBLESHOOTING.md                 # Detailed troubleshooting guide
└── ARCHITECTURE.md                    # Architecture deep dive
```

### Key Files to Know

| File | Purpose | Critical Settings |
|------|---------|-------------------|
| [airflow/values.yaml](airflow/values.yaml) | Airflow Helm config | `dags.persistence.enabled: false`<br>`waitForMigrations.enabled: false` for all components |
| [scripts/k8s-bootstrap.sh](scripts/k8s-bootstrap.sh) | Deployment automation | Runs DB migrations before Helm<br>Creates crypto_data table<br>Sets up MinIO buckets |
| [docker/Dockerfile.airflow](docker/Dockerfile.airflow) | Custom Airflow image | Base: `apache/airflow:3.0.2-python3.12`<br>Bakes in DAGs and dependencies |
| [dags/etl/config.py](dags/etl/config.py) | ETL configuration | Symbols, API endpoints, DB credentials |
| [dags/etl/extraction.py](dags/etl/extraction.py) | Binance data extraction | Pagination, rate limiting, MinIO upload |
| [dags/etl/loader.py](dags/etl/loader.py) | PostgreSQL loading | Schema definition, bulk insert, upsert |

---

## 🤝 Contributing

Contributions welcome! This boilerplate is designed to be community-driven.

**How to contribute:**
1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes
4. Test thoroughly (both Docker Compose and K8s)
5. Submit a Pull Request

**Areas needing help:**
- Additional model frameworks (PyTorch, TensorFlow native support)
- More monitoring dashboards (SLI/SLO templates)
- Cloud provider examples (AWS EKS, GCP GKE, Azure AKS)
- Training pipeline integration
- Testing infrastructure (unit tests, integration tests)
- Documentation improvements

---

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

---

## 🔗 Built With

- [FastAPI](https://fastapi.tiangolo.com/) - Modern, high-performance web framework
- [MLflow](https://mlflow.org/) - ML lifecycle management and model registry
- [Prometheus](https://prometheus.io/) - Monitoring and alerting toolkit
- [Grafana](https://grafana.com/) - Analytics and visualization platform
- [Kubernetes](https://kubernetes.io/) - Container orchestration
- [Redis](https://redis.io/) - In-memory data structure store
- [MinIO](https://min.io/) - High-performance object storage

---

**From trained models to production serving in minutes.**

---

## 📊 Current Implementation Status

| Component | Status | Details |
|-----------|--------|---------|
| **ETL Pipeline** | ✅ Fully Tested | 2.25M records loaded from Binance API |
| **ML Training Pipeline** | ⏳ Testing Pending | DAG deployed, infrastructure ready |
| **Inference API** | 📋 Planned | Deploy after ML training validates |
| **Monitoring** | ✅ Ready | Prometheus + Grafana deployed |

**Documentation:**
- [ML_PIPELINE_SUMMARY.md](ML_PIPELINE_SUMMARY.md) - Detailed ML pipeline documentation
- [QUICK_START.md](QUICK_START.md) - Quick start guide
- [DEPLOYMENT_SUMMARY.md](DEPLOYMENT_SUMMARY.md) - Deployment details

> **Current Focus:** ETL pipeline is production-ready. ML training pipeline is deployed and ready for end-to-end testing.

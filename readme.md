# ML Inference Infrastructure Boilerplate

**From trained models to production serving in minutes.**

[![Docker](https://img.shields.io/badge/Docker-Ready-blue)](https://www.docker.com/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-Ready-326CE5)](https://kubernetes.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **Note:** This boilerplate focuses on **inference/serving infrastructure**. Training pipeline integration is on the roadmap.

---

## 🎯 What Is This?

An ML inference boilerplate that provides the infrastructure to serve your trained models:

**What's Working Now:**
- ✅ **Local Testing** (Docker Compose) - Full stack with MLflow, API, monitoring in 5 minutes
- ✅ **Model Registry** (MLflow) - Version control and stage-based deployment
- ✅ **Inference API** (FastAPI) - REST API with auto-docs
- ✅ **Monitoring** (Prometheus + Grafana) - Metrics and dashboards
- ✅ **Docker Image** - Production-ready container builds successfully
- ✅ **Kubernetes Deployment** - Fully tested on Docker Desktop K8s (ARM64/Apple Silicon)

**What's Coming:**
- ⏳ **Training Pipeline** - Automated model training and registration
- ⏳ **Cloud Provider Examples** - AWS EKS, GCP GKE, Azure AKS templates

---

## 🚀 Quick Start (Local Testing)

### Step 1: Start Infrastructure (5 minutes)
```bash
# Clone repository
git clone <repo-url>
cd mlops-boilerplate

# Start all services with Docker Compose (for local testing)
docker-compose up -d

# Verify services are running
docker-compose ps

# Run validation to confirm everything works
./scripts/validate-deployment.sh --env docker
```

You now have:
- **MLflow UI**: http://localhost:5001 - Model registry
- **API Docs**: http://localhost:8000/docs - Interactive API
- **Grafana**: http://localhost:3000 (admin/admin) - Dashboards
- **Prometheus**: http://localhost:9090 - Metrics

### Step 2: Register Your Model in MLflow

```python
import mlflow
import mlflow.sklearn  # or mlflow.pytorch, mlflow.tensorflow, etc.

# Connect to running MLflow server
mlflow.set_tracking_uri("http://localhost:5001")
mlflow.set_experiment("my_experiment")

# Load your trained model
model = load_your_trained_model()

# Register model
with mlflow.start_run():
    mlflow.log_params({"model_type": "lightgbm", "version": "1.0"})
    mlflow.log_metrics({"accuracy": 0.95, "f1": 0.93})

    # Register with naming convention: crypto_{model_type}_{task}_{symbol}
    mlflow.sklearn.log_model(
        model,
        "model",
        registered_model_name="crypto_lightgbm_return_1step_BTCUSDT"
    )
```

### Step 3: Promote Model to Production

**IMPORTANT:** Just registering the model is **NOT enough**. The API loads models based on their **MLflow stage**.

**Option A: Using MLflow UI**
1. Go to http://localhost:5001
2. Navigate to "Models" tab
3. Find your registered model
4. Click on version → "Stage" → Select "Production"

**Option B: Programmatically**
```python
from mlflow.tracking import MlflowClient

client = MlflowClient()
client.transition_model_version_stage(
    name="crypto_lightgbm_return_1step_BTCUSDT",
    version=1,
    stage="Production"
)
```

### Step 4: Reload API to Load Models

```bash
# Option 1: Restart API container
docker-compose restart api

# Option 2: Use reload endpoint (hot reload)
curl -X POST "http://localhost:8000/models/reload"
```

### Step 5: Make Predictions

```bash
# Check health and loaded models
curl http://localhost:8000/health

# Get prediction
curl -X POST "http://localhost:8000/predict/BTCUSDT" \
  -H "Content-Type: application/json" \
  -d '{"tasks": ["return_1step"]}'
```

**Key Points:**
- ✅ Must promote model to "Production" stage for API to load it
- ✅ API loads models based on MLflow stage: Production → Staging → None
- ✅ Model naming convention: `crypto_{model_type}_{task}_{symbol}`
- ✅ Supported: scikit-learn, LightGBM, XGBoost, PyTorch, TensorFlow

---

## 📦 Production Deployment (Kubernetes)

> **✅ TESTED:** Docker Desktop Kubernetes (ARM64/Apple Silicon)

**Docker Compose is for local testing only. For production, use Kubernetes deployment.**

### One-Command Deployment

```bash
# Deploy complete infrastructure + API
./scripts/k8s-bootstrap.sh

# Validate everything is working
./scripts/validate-deployment.sh --env k8s
```

This deploys:
- MinIO (S3-compatible storage)
- Redis (feature caching)
- PostgreSQL (MLflow backend)
- MLflow (model registry)
- Prometheus + Grafana (monitoring)
- Inference API (2 replicas with HPA)

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
- ✅ Model serving infrastructure (FastAPI, MLflow, K8s)
- ✅ Auto-scaling based on load
- ✅ Monitoring and metrics
- ✅ Model versioning and stage-based deployment
- ✅ Production-grade security and health checks

### Coming Soon

**Training Pipeline Integration**
- End-to-end training pipeline
- Automated model training and registration
- Training job orchestration
- Experiment tracking integration

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

### API Returns 503 "No models loaded"

**Cause:** API is waiting for models to be registered and promoted to Production stage.

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
.
├── app/                          # Inference API
│   ├── production_api.py         # FastAPI application
│   └── requirements.txt          # Python dependencies
│
├── scripts/                      # Deployment & Validation Scripts
│   ├── k8s-bootstrap.sh          # One-command K8s deployment
│   └── validate-deployment.sh    # Validate Docker/K8s deployments
│
├── dags/                         # ML Pipeline
│   ├── inference_feature_pipeline.py  # Inference logic & task definitions
│   ├── feature_eng.py            # Feature engineering functions
│   ├── model_training.py         # Training utilities
│   └── data_versioning.py        # DVC integration
│
├── k8s/                          # Kubernetes Manifests (PRODUCTION)
│   ├── api-deployment.yaml       # Deployment spec with health probes
│   ├── api-service.yaml          # Service for load balancing
│   ├── api-hpa.yaml              # HorizontalPodAutoscaler
│   ├── api-ingress.yaml          # External access
│   ├── api-configmap.yaml        # Configuration
│   ├── api-servicemonitor.yaml   # Prometheus integration
│   ├── secrets.yaml.example      # Secrets template
│   ├── kustomization.yaml        # Kustomize config
│   └── README.md                 # Detailed K8s deployment guide
│
├── minio/                        # MinIO Helm values
│   └── values.yaml
├── redis/                        # Redis Helm values
│   └── values.yaml
├── mlflow/                       # MLflow Helm values
│   └── values.yaml
├── grafana/                      # Grafana Helm values
│   └── values.yaml
│
├── docker/                       # Docker Images
│   └── Dockerfile.inference      # Production API image
│
├── src/config/                   # Configuration Management
│   └── settings.py               # Pydantic settings
│
├── monitoring/                   # Monitoring Stack
│   ├── prometheus.yml            # Prometheus configuration
│   └── grafana/                  # Grafana dashboards
│
├── docker-compose.yml            # Local testing (NOT for production)
├── .env.example                  # Environment variables template
└── README.md                     # This file
```

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

> **Note:** This boilerplate focuses on **inference/serving infrastructure**. Training pipeline integration is on the roadmap.

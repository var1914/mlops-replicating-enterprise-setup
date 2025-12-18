# ML Inference Infrastructure Boilerplate

**Production-ready infrastructure for serving ML models at scale with monitoring, auto-scaling, and model versioning.**

[![Docker](https://img.shields.io/badge/Docker-Ready-blue)](https://www.docker.com/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-Ready-326CE5)](https://kubernetes.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## 🎯 What Is This?

A complete MLOps boilerplate that provides everything you need to serve ML models in production:

- **Model Registry** (MLflow) - Version control for ML models
- **Inference API** (FastAPI) - REST API for predictions
- **Storage** (MinIO/S3) - Model artifact storage
- **Caching** (Redis) - Fast feature caching
- **Monitoring** (Prometheus + Grafana) - Metrics and dashboards
- **Auto-scaling** (Kubernetes HPA) - Scale based on load
- **Production-grade** - Health checks, rolling updates, security

---

## 🚀 Quick Start (Local Testing)

### Step 1: Start Infrastructure (5 minutes)
```bash
# Clone repository
git clone <repo-url>
cd ml-eng-with-ops

# Start all services with Docker Compose (for local testing)
docker-compose up -d

# Verify services are running
docker-compose ps
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

**Docker Compose is for local testing only. For production, use Kubernetes deployment.**

### Prerequisites
- Kubernetes cluster (1.19+)
- kubectl configured
- Docker registry (Docker Hub, ECR, GCR, etc.)
- External MLflow server (or deploy MLflow separately)
- External PostgreSQL, Redis, MinIO/S3

### Step 1: Build and Push Docker Image

```bash
# Build inference API image
docker build -t your-registry/ml-inference-api:1.0.0 -f docker/Dockerfile.inference .

# Push to registry
docker push your-registry/ml-inference-api:1.0.0
```

### Step 2: Update Image in Deployment

Edit `k8s/api-deployment.yaml`:
```yaml
spec:
  template:
    spec:
      containers:
      - name: api
        image: your-registry/ml-inference-api:1.0.0  # Update this
```

### Step 3: Create Kubernetes Secrets

```bash
# Copy example and edit with your credentials
cp k8s/secrets.yaml.example k8s/secrets.yaml

# Edit k8s/secrets.yaml with:
# - Database credentials (your external PostgreSQL)
# - MinIO/S3 credentials (your external S3)
# - Redis password (your external Redis)

# Create namespace and secret
kubectl create namespace ml-pipeline
kubectl apply -f k8s/secrets.yaml
```

### Step 4: Update ConfigMap

Edit `k8s/api-configmap.yaml` with your external services:
```yaml
data:
  # Your external MLflow server
  MLFLOW_TRACKING_URI: "http://your-mlflow-server:5000"

  # Your external PostgreSQL
  DB_HOST: "your-postgres-host.rds.amazonaws.com"
  DB_PORT: "5432"
  DB_NAME: "your_database"

  # Your external Redis
  REDIS_HOST: "your-redis-host.cache.amazonaws.com"
  REDIS_PORT: "6379"

  # Your external MinIO/S3
  MINIO_ENDPOINT: "s3.amazonaws.com"  # or your MinIO endpoint
  MINIO_SECURE: "true"

  # Your entities
  BINANCE_SYMBOLS: '["ENTITY1","ENTITY2","ENTITY3"]'
```

### Step 5: Deploy to Kubernetes

```bash
# Apply all resources
kubectl apply -f k8s/

# Verify deployment
kubectl get pods -n ml-pipeline
kubectl get svc -n ml-pipeline
kubectl get hpa -n ml-pipeline

# Check logs
kubectl logs -n ml-pipeline -l app=crypto-prediction-api --tail=100
```

### Step 6: Access the API

**Option 1: Port Forward (for testing)**
```bash
kubectl port-forward -n ml-pipeline svc/crypto-prediction-api 8000:8000
curl http://localhost:8000/health
```

**Option 2: Configure Ingress (for production)**

Edit `k8s/api-ingress.yaml` with your domain:
```yaml
spec:
  rules:
  - host: api.yourdomain.com  # Update this
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: crypto-prediction-api
            port:
              number: 8000
  tls:
  - hosts:
    - api.yourdomain.com  # Update this
    secretName: api-tls-cert  # Your TLS certificate secret
```

Then deploy:
```bash
kubectl apply -f k8s/api-ingress.yaml
```

Access via: `https://api.yourdomain.com`

### Production Features Included

| Feature | File | What It Does |
|---------|------|--------------|
| **Auto-scaling** | `k8s/api-hpa.yaml` | Scales 2-10 pods based on CPU/memory (70%/80%) |
| **Health Probes** | `k8s/api-deployment.yaml` | Liveness, readiness, startup probes |
| **Rolling Updates** | `k8s/api-deployment.yaml` | Zero-downtime deployments (maxSurge: 1, maxUnavailable: 0) |
| **Resource Limits** | `k8s/api-deployment.yaml` | CPU: 500m-2000m, Memory: 1Gi-4Gi |
| **Monitoring** | `k8s/api-servicemonitor.yaml` | Prometheus scraping configured |
| **Load Balancing** | `k8s/api-service.yaml` | ClusterIP service with pod distribution |
| **Ingress** | `k8s/api-ingress.yaml` | External access with SSL/TLS |
| **Security** | `k8s/api-deployment.yaml` | Non-root user (UID 1000), secrets management |

### Monitoring in Production

**Prometheus Scraping:**
- ServiceMonitor configured for automatic discovery
- Metrics endpoint: `/metrics`
- Scrape interval: 30s

**Grafana Dashboards:**
- Import dashboards from `monitoring/grafana/`
- Connect to your Prometheus instance
- Pre-configured for API metrics

**Scaling Behavior:**
- Scales up: 100% increase or +4 pods per 30s (whichever is higher)
- Scales down: 50% decrease or -2 pods per 60s (whichever is lower)
- Stabilization: 60s for scale-up, 300s for scale-down

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
├── dags/                         # ML Pipeline
│   ├── inference_feature_pipeline.py  # Inference logic & task definitions
│   ├── feature_eng.py            # Feature engineering functions
│   ├── model_training.py         # Training utilities
│   └── data_versioning.py        # DVC integration
│
├── k8s/                          # Kubernetes Manifests (PRODUCTION)
│   ├── api-deployment.yaml       # Deployment spec with health probes
│   ├── api-service.yaml          # Service for load balancing
│   ├── api-hpa.yaml             # HorizontalPodAutoscaler
│   ├── api-ingress.yaml         # External access
│   ├── api-configmap.yaml       # Configuration
│   ├── api-servicemonitor.yaml  # Prometheus integration
│   ├── secrets.yaml.example     # Secrets template
│   └── kustomization.yaml       # Kustomize config
│
├── docker/                       # Docker Images
│   └── Dockerfile.inference     # Production API image
│
├── src/config/                   # Configuration Management
│   └── settings.py              # Pydantic settings
│
├── monitoring/                   # Monitoring Stack
│   ├── prometheus.yml           # Prometheus configuration
│   └── grafana/                 # Grafana dashboards
│
├── docker-compose.yml           # Local testing (NOT for production)
├── .env.example                 # Environment variables template
└── README.md                    # This file
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

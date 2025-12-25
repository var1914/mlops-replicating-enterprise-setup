# Kubernetes Deployment Guide

Complete guide for deploying the ML Inference Infrastructure on Kubernetes.

> **Status:** Tested on Docker Desktop Kubernetes (ARM64/Apple Silicon)

---

## Quick Start

### One-Command Deployment

```bash
# Deploy everything (infrastructure + API)
./scripts/k8s-bootstrap.sh

# Validate deployment
./scripts/validate-deployment.sh --env k8s
```

### Cleanup

```bash
./scripts/k8s-bootstrap.sh --cleanup
```

---

## What Gets Deployed

| Component | Helm Chart / Method | Service Name | Port |
|-----------|---------------------|--------------|------|
| MinIO | bitnami/minio | ml-minio | 9000 |
| Redis | bitnami/redis | ml-redis-master | 6379 |
| PostgreSQL | K8s Manifest | postgresql | 5432 |
| MLflow | community-charts/mlflow | ml-mlflow | 5000 |
| Prometheus | kube-prometheus-stack | ml-monitoring-prometheus | 9090 |
| Grafana | kube-prometheus-stack | ml-monitoring-grafana | 80 |
| Inference API | Kustomize | crypto-prediction-api | 8000 |

---

## Prerequisites

- Docker Desktop with Kubernetes enabled (or any K8s cluster 1.20+)
- kubectl configured
- Helm 3.x installed
- ~8GB RAM available for Docker Desktop

### Verify Prerequisites

```bash
# Check kubectl
kubectl version --client

# Check helm
helm version

# Check cluster connection
kubectl cluster-info
```

---

## Deployment Options

### Option 1: Full Deployment (Recommended)

Deploys all infrastructure and API:

```bash
./scripts/k8s-bootstrap.sh
```

### Option 2: Infrastructure Only

Deploy only supporting services (MinIO, Redis, PostgreSQL, MLflow, Monitoring):

```bash
./scripts/k8s-bootstrap.sh --infra-only
```

### Option 3: API Only

Deploy only the inference API (requires infrastructure to be running):

```bash
./scripts/k8s-bootstrap.sh --api-only
```

### Option 4: Individual Components

Deploy components one at a time:

```bash
# Add Helm repos
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add community-charts https://community-charts.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace ml-pipeline

# Deploy MinIO
helm upgrade --install ml-minio bitnami/minio \
  --namespace ml-pipeline \
  --values ../minio/values.yaml

# Deploy Redis
helm upgrade --install ml-redis bitnami/redis \
  --namespace ml-pipeline \
  --values ../redis/values.yaml

# Deploy MLflow
helm upgrade --install ml-mlflow community-charts/mlflow \
  --namespace ml-pipeline \
  --values ../mlflow/values.yaml

# Deploy Monitoring
helm upgrade --install ml-monitoring prometheus-community/kube-prometheus-stack \
  --namespace ml-pipeline \
  --values ../grafana/values.yaml

# Deploy API
kubectl apply -k .
```

---

## Accessing Services

### Port Forwarding (Development/Testing)

```bash
# Inference API
kubectl port-forward -n ml-pipeline svc/crypto-prediction-api 8000:8000
# Access: http://localhost:8000/docs

# MLflow UI
kubectl port-forward -n ml-pipeline svc/ml-mlflow 5000:5000
# Access: http://localhost:5000

# Grafana
kubectl port-forward -n ml-pipeline svc/ml-monitoring-grafana 3000:80
# Access: http://localhost:3000 (admin / prom-operator)

# MinIO Console
kubectl port-forward -n ml-pipeline svc/ml-minio-console 9090:9090
# Access: http://localhost:9090 (admin / admin123)

# Prometheus
kubectl port-forward -n ml-pipeline svc/ml-monitoring-kube-prometh-prometheus 9090:9090
# Access: http://localhost:9090
```

### Using Ingress (Production)

Uncomment ingress in `kustomization.yaml` and configure `api-ingress.yaml`:

```yaml
# kustomization.yaml
resources:
  - api-ingress.yaml  # Uncomment this
```

```yaml
# api-ingress.yaml
spec:
  rules:
  - host: api.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: crypto-prediction-api
            port:
              number: 8000
```

---

## Configuration

### Helm Values Files

| File | Purpose |
|------|---------|
| `../minio/values.yaml` | MinIO configuration (credentials, buckets) |
| `../redis/values.yaml` | Redis configuration (password, persistence) |
| `../mlflow/values.yaml` | MLflow configuration (backend store, artifact root) |
| `../grafana/values.yaml` | Prometheus + Grafana configuration |

### API Configuration

| File | Purpose |
|------|---------|
| `api-configmap.yaml` | Non-sensitive config (endpoints, ports) |
| `secrets.yaml.example` | Template for secrets (copy to secrets.yaml) |
| `api-deployment.yaml` | Deployment spec (replicas, resources, probes) |
| `api-hpa.yaml` | Auto-scaling configuration |

### Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| MinIO | admin | admin123 |
| Redis | - | redis123 |
| PostgreSQL | mlflow | mlflow123 |
| Grafana | admin | prom-operator |

> **Production:** Change all default passwords before deploying to production!

---

## Customization

### Using External Services

For production with managed services (AWS RDS, ElastiCache, S3):

1. **Update ConfigMap** (`api-configmap.yaml`):

```yaml
data:
  DB_HOST: "your-rds.amazonaws.com"
  DB_PORT: "5432"
  REDIS_HOST: "your-elasticache.amazonaws.com"
  MINIO_ENDPOINT: "s3.amazonaws.com"
  MINIO_SECURE: "true"
  MLFLOW_TRACKING_URI: "http://your-mlflow-server:5000"
```

2. **Update Secrets** (`secrets.yaml`):

```bash
# Generate base64 encoded values
echo -n "your-db-password" | base64
echo -n "your-redis-password" | base64
echo -n "your-aws-access-key" | base64
echo -n "your-aws-secret-key" | base64
```

3. **Skip Infrastructure Deployment**:

```bash
./scripts/k8s-bootstrap.sh --api-only
```

### Scaling Configuration

Edit `api-hpa.yaml`:

```yaml
spec:
  minReplicas: 2      # Minimum pods
  maxReplicas: 10     # Maximum pods
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

### Resource Limits

Edit `api-deployment.yaml`:

```yaml
resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "2000m"
    memory: "4Gi"
```

---

## Monitoring

### Prometheus Metrics

The API exposes metrics at `/metrics`:

```bash
kubectl port-forward -n ml-pipeline svc/crypto-prediction-api 8000:8000
curl http://localhost:8000/metrics
```

Key metrics:
- `prediction_requests_total` - Total predictions by symbol/task
- `prediction_duration_seconds` - Prediction latency
- `loaded_models_total` - Number of loaded models
- `http_requests_total` - HTTP request count

### Grafana Dashboards

1. Access Grafana:
   ```bash
   kubectl port-forward -n ml-pipeline svc/ml-monitoring-grafana 3000:80
   ```

2. Login: admin / prom-operator

3. Import dashboards from `../monitoring/grafana/dashboards/`

### ServiceMonitor

For automatic Prometheus discovery, uncomment in `kustomization.yaml`:

```yaml
resources:
  - api-servicemonitor.yaml
```

---

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n ml-pipeline
kubectl describe pod <pod-name> -n ml-pipeline
kubectl logs <pod-name> -n ml-pipeline
```

### Common Issues

#### Pods Stuck in Pending

```bash
# Check node resources
kubectl describe nodes

# Check pod events
kubectl describe pod <pod-name> -n ml-pipeline
```

**Solutions:**
- Increase Docker Desktop memory (8GB recommended)
- Check for resource constraints in deployment

#### Image Pull Errors

```bash
# Check image pull status
kubectl describe pod <pod-name> -n ml-pipeline | grep -A5 Events
```

**Solutions:**
- Verify image exists: `docker images | grep crypto-prediction-api`
- For remote registries, create image pull secret

#### CrashLoopBackOff

```bash
# Check logs
kubectl logs <pod-name> -n ml-pipeline --previous
```

**Common causes:**
- Missing secrets
- Wrong service endpoints in ConfigMap
- Health check failing

#### MLflow Connection Issues

```bash
# Test from API pod
kubectl exec -it deployment/crypto-prediction-api -n ml-pipeline -- \
  curl http://ml-mlflow:5000/health
```

#### Redis Connection Issues

```bash
# Test from API pod
kubectl exec -it deployment/crypto-prediction-api -n ml-pipeline -- \
  python3 -c "import redis; r = redis.Redis(host='ml-redis-master', port=6379, password='redis123'); print(r.ping())"
```

### Reset Everything

```bash
./scripts/k8s-bootstrap.sh --cleanup
./scripts/k8s-bootstrap.sh
```

---

## Files Reference

| File | Description |
|------|-------------|
| `api-configmap.yaml` | Non-sensitive configuration |
| `api-deployment.yaml` | Main API deployment (2 replicas) |
| `api-service.yaml` | ClusterIP service |
| `api-hpa.yaml` | Horizontal Pod Autoscaler |
| `api-ingress.yaml` | Ingress (optional) |
| `api-servicemonitor.yaml` | Prometheus ServiceMonitor (optional) |
| `secrets.yaml.example` | Secrets template |
| `kustomization.yaml` | Kustomize configuration |
| `deploy.sh` | Legacy deployment script |

---

## Production Checklist

Before deploying to production:

- [ ] Change all default passwords
- [ ] Update ConfigMap with production endpoints
- [ ] Create secrets with production credentials
- [ ] Push Docker image to production registry
- [ ] Update image reference in kustomization.yaml
- [ ] Configure Ingress with TLS
- [ ] Set appropriate resource limits
- [ ] Configure backup for PostgreSQL
- [ ] Set up alerting rules
- [ ] Test failover and recovery
- [ ] Document runbooks

---

## Architecture

```
                                    +-------------------------------------+
                                    |         Kubernetes Cluster          |
                                    |                                     |
                                    |  +-------------------------------+  |
                                    |  |     ml-pipeline namespace     |  |
+----------+                        |  |                               |  |
|  Client  |----------------------->|  |   +-----------------------+   |  |
+----------+                        |  |   |  Inference API (HPA)  |   |  |
                                    |  |   |   crypto-prediction   |   |  |
                                    |  |   |    2-10 replicas      |   |  |
                                    |  |   +-----------+-----------+   |  |
                                    |  |               |               |  |
                                    |  |     +---------+---------+     |  |
                                    |  |     |         |         |     |  |
                                    |  |     v         v         v     |  |
                                    |  | +-------+ +-------+ +-------+ |  |
                                    |  | |MLflow | | Redis | | MinIO | |  |
                                    |  | | :5000 | | :6379 | | :9000 | |  |
                                    |  | +---+---+ +-------+ +-------+ |  |
                                    |  |     |                         |  |
                                    |  |     v                         |  |
                                    |  | +---------+                   |  |
                                    |  | |PostgreSQL|                  |  |
                                    |  | |  :5432  |                   |  |
                                    |  | +---------+                   |  |
                                    |  |                               |  |
                                    |  | +---------------------------+ |  |
                                    |  | |  Monitoring (Prometheus   | |  |
                                    |  | |    + Grafana)             | |  |
                                    |  | +---------------------------+ |  |
                                    |  |                               |  |
                                    |  +-------------------------------+  |
                                    +-------------------------------------+
```

---

## Support

- Validate deployment: `./scripts/validate-deployment.sh --env k8s`
- Check logs: `kubectl logs -f deployment/crypto-prediction-api -n ml-pipeline`
- Status: `./scripts/k8s-bootstrap.sh --status`
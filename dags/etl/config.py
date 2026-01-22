"""
ETL Pipeline Configuration

Centralized configuration for the ETL pipeline.
Reads from environment variables for K8s/Docker Compose compatibility.
"""

import os
from typing import Dict, List

# Symbols to extract
SYMBOLS: List[str] = [
    'BTCUSDT', 'ETHUSDT', 'BNBUSDT', 'ADAUSDT', 'SOLUSDT',
    'XRPUSDT', 'DOTUSDT', 'AVAXUSDT', 'MATICUSDT', 'LINKUSDT'
]

# Binance API Configuration
BINANCE_CONFIG = {
    'base_url': os.getenv('BINANCE_BASE_URL', 'https://api.binance.com/api/v3/klines'),
    'interval': os.getenv('BINANCE_INTERVAL', '15m'),
    'batch_size': int(os.getenv('BINANCE_BATCH_SIZE', '1000')),
    'total_limit': int(os.getenv('BINANCE_TOTAL_LIMIT', '250000')),  # Per symbol (250k x 10 = 2.5M total)
}

# MinIO Configuration
MINIO_CONFIG = {
    'endpoint': os.getenv('MINIO_ENDPOINT', 'minio:9000'),  # K8s service name
    'access_key': os.getenv('MINIO_ACCESS_KEY', 'admin'),
    'secret_key': os.getenv('MINIO_SECRET_KEY', 'admin123'),
    'secure': os.getenv('MINIO_SECURE', 'false').lower() == 'true',
    'raw_bucket': os.getenv('MINIO_RAW_BUCKET', 'crypto-raw-data'),
    'features_bucket': os.getenv('MINIO_FEATURES_BUCKET', 'crypto-features'),
}

# PostgreSQL Configuration - Crypto Database (ETL raw data)
DB_CONFIG = {
    'host': os.getenv('CRYPTO_DB_HOST', os.getenv('DB_HOST', 'postgresql')),  # K8s service name
    'port': int(os.getenv('CRYPTO_DB_PORT', os.getenv('DB_PORT', '5432'))),
    'dbname': os.getenv('CRYPTO_DB_NAME', 'crypto'),  # Separate database for ETL data
    'user': os.getenv('CRYPTO_DB_USER', 'crypto'),
    'password': os.getenv('CRYPTO_DB_PASSWORD', 'crypto123'),
}

# MLflow Database Configuration (separate from ETL)
MLFLOW_DB_CONFIG = {
    'host': os.getenv('MLFLOW_DB_HOST', os.getenv('DB_HOST', 'postgresql')),
    'port': int(os.getenv('MLFLOW_DB_PORT', os.getenv('DB_PORT', '5432'))),
    'dbname': os.getenv('MLFLOW_DB_NAME', 'mlflow'),
    'user': os.getenv('MLFLOW_DB_USER', 'mlflow'),
    'password': os.getenv('MLFLOW_DB_PASSWORD', 'mlflow123'),
}

# Redis Configuration
REDIS_CONFIG = {
    'host': os.getenv('REDIS_HOST', 'ml-redis-master'),
    'port': int(os.getenv('REDIS_PORT', '6379')),
    'password': os.getenv('REDIS_PASSWORD', 'redis123'),
}

# MLflow Configuration
MLFLOW_CONFIG = {
    'tracking_uri': os.getenv('MLFLOW_TRACKING_URI', 'http://ml-mlflow:5000'),
}

# Combined ETL Config
ETL_CONFIG = {
    'symbols': SYMBOLS,
    'binance': BINANCE_CONFIG,
    'minio': MINIO_CONFIG,
    'database': DB_CONFIG,
    'redis': REDIS_CONFIG,
    'mlflow': MLFLOW_CONFIG,
}


def get_minio_client():
    """Get MinIO client instance."""
    from minio import Minio

    return Minio(
        MINIO_CONFIG['endpoint'],
        access_key=MINIO_CONFIG['access_key'],
        secret_key=MINIO_CONFIG['secret_key'],
        secure=MINIO_CONFIG['secure']
    )


def get_db_connection():
    """Get PostgreSQL connection."""
    import psycopg2

    return psycopg2.connect(
        host=DB_CONFIG['host'],
        port=DB_CONFIG['port'],
        dbname=DB_CONFIG['dbname'],
        user=DB_CONFIG['user'],
        password=DB_CONFIG['password']
    )


def get_redis_client():
    """Get Redis client instance."""
    import redis

    return redis.Redis(
        host=REDIS_CONFIG['host'],
        port=REDIS_CONFIG['port'],
        password=REDIS_CONFIG['password'],
        decode_responses=True
    )

"""
Configuration settings for ML Pipeline using Pydantic BaseSettings.
All sensitive credentials should be stored in environment variables or .env files.
"""

from pydantic_settings import BaseSettings
from pydantic import Field, field_validator
from typing import Optional, List
from functools import lru_cache
import os


class DatabaseConfig(BaseSettings):
    """Database configuration"""
    host: str = Field(default="localhost", description="Database host")
    port: int = Field(default=5432, description="Database port")
    name: str = Field(default="postgres", description="Database name")
    user: str = Field(default="postgres", description="Database user")
    password: str = Field(description="Database password")

    class Config:
        env_prefix = "DB_"
        case_sensitive = False

    def get_connection_dict(self) -> dict:
        """Returns connection dictionary for psycopg2"""
        return {
            "host": self.host,
            "port": self.port,
            "dbname": self.name,
            "user": self.user,
            "password": self.password
        }

    def get_uri(self) -> str:
        """Returns database URI string"""
        return f"postgresql://{self.user}:{self.password}@{self.host}:{self.port}/{self.name}"


class MinIOConfig(BaseSettings):
    """MinIO/S3 configuration"""
    endpoint: str = Field(default="minio:9000", description="MinIO endpoint")
    access_key: str = Field(description="MinIO access key")
    secret_key: str = Field(description="MinIO secret key")
    secure: bool = Field(default=False, description="Use HTTPS")
    bucket_models: str = Field(default="crypto-models", description="Models bucket name")
    bucket_features: str = Field(default="crypto-features", description="Features bucket name")
    bucket_data_versions: str = Field(default="crypto-data-versions", description="Data versions bucket")

    class Config:
        env_prefix = "MINIO_"
        case_sensitive = False

    def get_client_config(self) -> dict:
        """Returns configuration for MinIO client"""
        return {
            "endpoint": self.endpoint,
            "access_key": self.access_key,
            "secret_key": self.secret_key,
            "secure": self.secure
        }


class RedisConfig(BaseSettings):
    """Redis configuration"""
    host: str = Field(default="localhost", description="Redis host")
    port: int = Field(default=6379, description="Redis port")
    db: int = Field(default=0, description="Redis database number")
    password: Optional[str] = Field(default=None, description="Redis password (optional)")

    class Config:
        env_prefix = "REDIS_"
        case_sensitive = False

    def get_client_config(self) -> dict:
        """Returns configuration for Redis client"""
        config = {
            "host": self.host,
            "port": self.port,
            "db": self.db,
            "decode_responses": True
        }
        if self.password:
            config["password"] = self.password
        return config


class MLflowConfig(BaseSettings):
    """MLflow configuration"""
    tracking_uri: str = Field(default="http://mlflow-tracking:5000", description="MLflow tracking server URI")
    experiment_prefix: str = Field(default="crypto_multi_models", description="Experiment name prefix")
    registry_uri: Optional[str] = Field(default=None, description="MLflow registry URI (optional)")
    backend_store_uri: Optional[str] = Field(default=None, description="MLflow backend store URI")
    artifact_root: Optional[str] = Field(default="s3://mlflow-artifacts", description="Default artifact root")

    class Config:
        env_prefix = "MLFLOW_"
        case_sensitive = False


class DVCConfig(BaseSettings):
    """DVC configuration"""
    remote_name: str = Field(default="minio", description="DVC remote name")
    remote_url: str = Field(default="s3://dvc-storage", description="DVC remote URL")
    access_key_id: Optional[str] = Field(default=None, description="AWS/S3 access key")
    secret_access_key: Optional[str] = Field(default=None, description="AWS/S3 secret key")
    endpoint_url: Optional[str] = Field(default="http://minio:9000", description="S3 endpoint URL")

    class Config:
        env_prefix = "DVC_"
        case_sensitive = False


class BinanceConfig(BaseSettings):
    """Binance API configuration"""
    base_url: str = Field(default="https://api.binance.com/api/v3/klines", description="Binance API base URL")
    symbols: List[str] = Field(
        default=[
            'BTCUSDT', 'ETHUSDT', 'BNBUSDT', 'ADAUSDT', 'SOLUSDT',
            'XRPUSDT', 'DOTUSDT', 'AVAXUSDT', 'MATICUSDT', 'LINKUSDT'
        ],
        description="List of trading symbols"
    )
    interval: str = Field(default="15m", description="Candle interval")

    class Config:
        env_prefix = "BINANCE_"
        case_sensitive = False

    @field_validator('symbols', mode='before')
    @classmethod
    def parse_symbols(cls, v):
        """Parse comma-separated symbols string"""
        if isinstance(v, str):
            return [s.strip() for s in v.split(',')]
        return v


class APIConfig(BaseSettings):
    """API server configuration"""
    host: str = Field(default="0.0.0.0", description="API host")
    port: int = Field(default=8000, description="API port")
    workers: int = Field(default=4, description="Number of worker processes")
    reload: bool = Field(default=False, description="Auto-reload on code changes")
    log_level: str = Field(default="info", description="Logging level")
    cors_origins: List[str] = Field(default=["*"], description="CORS allowed origins")
    rate_limit: str = Field(default="100/minute", description="Rate limit per client")

    class Config:
        env_prefix = "API_"
        case_sensitive = False

    @field_validator('cors_origins', mode='before')
    @classmethod
    def parse_cors_origins(cls, v):
        """Parse comma-separated CORS origins"""
        if isinstance(v, str):
            return [s.strip() for s in v.split(',')]
        return v


class MonitoringConfig(BaseSettings):
    """Monitoring and observability configuration"""
    prometheus_pushgateway: str = Field(
        default="prometheus-pushgateway:9091",
        description="Prometheus pushgateway endpoint"
    )
    sentry_dsn: Optional[str] = Field(default=None, description="Sentry DSN for error tracking")
    log_level: str = Field(default="INFO", description="Application log level")
    enable_metrics: bool = Field(default=True, description="Enable Prometheus metrics")
    enable_tracing: bool = Field(default=False, description="Enable distributed tracing")

    class Config:
        env_prefix = "MONITORING_"
        case_sensitive = False


class Settings(BaseSettings):
    """Main application settings"""

    # Environment
    environment: str = Field(default="development", description="Environment: development, staging, production")
    debug: bool = Field(default=False, description="Debug mode")

    # Component configurations
    database: DatabaseConfig = Field(default_factory=DatabaseConfig)
    minio: MinIOConfig = Field(default_factory=MinIOConfig)
    redis: RedisConfig = Field(default_factory=RedisConfig)
    mlflow: MLflowConfig = Field(default_factory=MLflowConfig)
    dvc: DVCConfig = Field(default_factory=DVCConfig)
    binance: BinanceConfig = Field(default_factory=BinanceConfig)
    api: APIConfig = Field(default_factory=APIConfig)
    monitoring: MonitoringConfig = Field(default_factory=MonitoringConfig)

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        case_sensitive = False
        env_nested_delimiter = "__"

    @field_validator('environment')
    @classmethod
    def validate_environment(cls, v):
        """Validate environment value"""
        allowed = ['development', 'staging', 'production']
        if v.lower() not in allowed:
            raise ValueError(f"Environment must be one of {allowed}")
        return v.lower()

    def is_production(self) -> bool:
        """Check if running in production"""
        return self.environment == "production"

    def is_development(self) -> bool:
        """Check if running in development"""
        return self.environment == "development"


@lru_cache()
def get_settings() -> Settings:
    """
    Get cached settings instance.
    This function is cached to ensure settings are loaded only once.
    """
    # Determine which env file to load based on ENVIRONMENT variable
    env = os.getenv("ENVIRONMENT", "development")
    env_file = f".env.{env}"

    # Check if environment-specific file exists, fallback to .env
    if not os.path.exists(env_file):
        env_file = ".env"

    if os.path.exists(env_file):
        return Settings(_env_file=env_file)
    else:
        # No .env file, load from environment variables only
        return Settings()


# Convenience function to get specific configs
def get_db_config() -> DatabaseConfig:
    """Get database configuration"""
    return get_settings().database


def get_minio_config() -> MinIOConfig:
    """Get MinIO configuration"""
    return get_settings().minio


def get_redis_config() -> RedisConfig:
    """Get Redis configuration"""
    return get_settings().redis


def get_mlflow_config() -> MLflowConfig:
    """Get MLflow configuration"""
    return get_settings().mlflow


def get_dvc_config() -> DVCConfig:
    """Get DVC configuration"""
    return get_settings().dvc


def get_binance_config() -> BinanceConfig:
    """Get Binance configuration"""
    return get_settings().binance


def get_api_config() -> APIConfig:
    """Get API configuration"""
    return get_settings().api


def get_monitoring_config() -> MonitoringConfig:
    """Get monitoring configuration"""
    return get_settings().monitoring

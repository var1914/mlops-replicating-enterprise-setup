"""
ETL Pre-checks Module

Health checks for API, database, and system resources before ETL execution.
Adapted from data-engineering-course-yt for ml-eng-with-ops.
"""

import logging
import threading
from typing import Dict, Any, Optional

import requests
import psutil
import psycopg2
from psycopg2 import pool

from .config import ETL_CONFIG, BINANCE_CONFIG, DB_CONFIG, MINIO_CONFIG


class DatabasePool:
    """Singleton Connection Pool Manager"""
    _instance = None
    _lock = threading.Lock()

    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super(DatabasePool, cls).__new__(cls)
                    cls._instance.pool = None
        return cls._instance

    def create_pool(self, db_config: Dict, min_conn: int = 2, max_conn: int = 10):
        """Create connection pool if not exists."""
        if self.pool is None:
            try:
                self.pool = psycopg2.pool.ThreadedConnectionPool(
                    min_conn, max_conn, **db_config
                )
                return "Connection pool created successfully"
            except psycopg2.Error as e:
                raise Exception(f"Failed to create connection pool: {str(e)}")
        return "Connection pool already exists"

    def get_connection(self):
        """Get connection from pool."""
        if self.pool:
            return self.pool.getconn()
        return None

    def put_connection(self, conn):
        """Return connection to pool."""
        if self.pool and conn:
            self.pool.putconn(conn)

    def close_pool(self):
        """Close all connections in pool."""
        if self.pool:
            self.pool.closeall()
            self.pool = None
            return "Connection pool closed"
        return "No pool to close"

    def get_pool_status(self) -> Dict:
        """Get pool connection stats."""
        if self.pool:
            return {
                "pool_exists": True,
                "pool_type": "ThreadedConnectionPool"
            }
        return {"pool_exists": False}


class PreChecks:
    """Pre-flight checks for ETL pipeline."""

    def __init__(
        self,
        base_url: str = None,
        headers: Dict = None,
        db_config: Dict = None
    ):
        self.base_url = base_url or BINANCE_CONFIG['base_url']
        self.headers = headers or {"Content-Type": "application/json"}
        self.db_config = db_config or DB_CONFIG
        self.db_pool = DatabasePool()
        self.logger = logging.getLogger("PreChecks")

    def check_binance_api(self) -> Dict[str, Any]:
        """Check Binance API availability."""
        try:
            # Use exchange info endpoint for health check
            response = requests.get(
                "https://api.binance.com/api/v3/ping",
                headers=self.headers,
                timeout=10
            )

            if response.status_code == 200:
                return {
                    "status": "healthy",
                    "message": "Binance API is accessible",
                    "response_time_ms": response.elapsed.total_seconds() * 1000
                }
            else:
                return {
                    "status": "unhealthy",
                    "message": f"Binance API returned status {response.status_code}"
                }

        except requests.exceptions.RequestException as e:
            return {
                "status": "error",
                "message": f"Binance API check failed: {str(e)}"
            }

    def check_minio(self) -> Dict[str, Any]:
        """Check MinIO availability."""
        try:
            from minio import Minio

            client = Minio(
                MINIO_CONFIG['endpoint'],
                access_key=MINIO_CONFIG['access_key'],
                secret_key=MINIO_CONFIG['secret_key'],
                secure=MINIO_CONFIG['secure']
            )

            # Try to list buckets as health check
            buckets = client.list_buckets()

            return {
                "status": "healthy",
                "message": "MinIO is accessible",
                "buckets_count": len(buckets),
                "buckets": [b.name for b in buckets]
            }

        except Exception as e:
            return {
                "status": "error",
                "message": f"MinIO check failed: {str(e)}"
            }

    def check_database(self) -> Dict[str, Any]:
        """Check PostgreSQL database connectivity."""
        try:
            conn = psycopg2.connect(**self.db_config)
            cursor = conn.cursor()
            cursor.execute("SELECT version();")
            version = cursor.fetchone()[0]
            cursor.close()
            conn.close()

            return {
                "status": "healthy",
                "message": "Database is accessible",
                "version": version
            }

        except psycopg2.Error as e:
            return {
                "status": "error",
                "message": f"Database check failed: {str(e)}"
            }

    def check_redis(self) -> Dict[str, Any]:
        """Check Redis connectivity."""
        try:
            import redis
            from .config import REDIS_CONFIG

            client = redis.Redis(
                host=REDIS_CONFIG['host'],
                port=REDIS_CONFIG['port'],
                password=REDIS_CONFIG['password']
            )

            if client.ping():
                info = client.info()
                return {
                    "status": "healthy",
                    "message": "Redis is accessible",
                    "version": info.get('redis_version'),
                    "connected_clients": info.get('connected_clients')
                }

        except Exception as e:
            return {
                "status": "error",
                "message": f"Redis check failed: {str(e)}"
            }

    def check_system_resources(self) -> Dict[str, Any]:
        """Check available system resources."""
        try:
            memory = psutil.virtual_memory()
            cpu_cores = psutil.cpu_count(logical=False)
            logical_cores = psutil.cpu_count(logical=True)
            cpu_usage = psutil.cpu_percent(interval=1)

            # Check if resources are sufficient
            min_ram_gb = 2.0
            available_ram_gb = memory.available / (1024 ** 3)

            status = "healthy" if available_ram_gb >= min_ram_gb else "warning"

            return {
                "status": status,
                "available_ram_gb": round(available_ram_gb, 2),
                "total_ram_gb": round(memory.total / (1024 ** 3), 2),
                "ram_usage_percent": memory.percent,
                "physical_cpu_cores": cpu_cores,
                "logical_cpu_cores": logical_cores,
                "cpu_usage_percent": cpu_usage
            }

        except Exception as e:
            return {
                "status": "error",
                "message": f"System resource check failed: {str(e)}"
            }

    def run_all_checks(self) -> Dict[str, Any]:
        """Run all pre-flight checks."""
        self.logger.info("Running ETL pre-flight checks...")

        results = {
            "binance_api": self.check_binance_api(),
            "minio": self.check_minio(),
            "database": self.check_database(),
            "redis": self.check_redis(),
            "system_resources": self.check_system_resources(),
            "pool_status": self.db_pool.get_pool_status()
        }

        # Determine overall status
        all_healthy = all(
            r.get("status") == "healthy"
            for r in results.values()
            if isinstance(r, dict) and "status" in r
        )

        results["overall_status"] = "healthy" if all_healthy else "degraded"

        self.logger.info(f"Pre-flight checks complete: {results['overall_status']}")

        return results


def run_prechecks(**context) -> Dict[str, Any]:
    """Airflow task function for pre-checks."""
    checker = PreChecks()
    return checker.run_all_checks()

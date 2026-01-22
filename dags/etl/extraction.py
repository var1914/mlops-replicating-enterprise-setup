"""
Data Extraction Module

Extracts OHLCV data from Binance API and stores in MinIO.
Adapted from data-engineering-course-yt for ml-eng-with-ops.
"""

import json
import logging
import time
from datetime import datetime
from io import BytesIO
from typing import Dict, Any, Iterator, List, Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from minio import Minio
from minio.error import S3Error

from .config import BINANCE_CONFIG, MINIO_CONFIG


class MinIODataExtractor:
    """Data Extractor with MinIO Storage."""

    def __init__(self, symbol: str, base_url: str = None):
        self.symbol = symbol
        self.base_url = base_url or BINANCE_CONFIG['base_url']
        self.logger = logging.getLogger(f"extractor_{symbol}")
        self.minio_client = self._get_minio_client()
        self._ensure_bucket_exists()
        self.session = self._create_session()
        self.request_count = 0

    def _create_session(self) -> requests.Session:
        """Create session with connection pooling and retry logic."""
        session = requests.Session()

        retry_strategy = Retry(
            total=5,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["HEAD", "GET", "OPTIONS"]
        )

        adapter = HTTPAdapter(
            max_retries=retry_strategy,
            pool_connections=5,
            pool_maxsize=10,
            pool_block=True
        )

        session.mount("https://", adapter)
        return session

    def _get_minio_client(self) -> Minio:
        """Initialize MinIO client."""
        try:
            client = Minio(
                MINIO_CONFIG['endpoint'],
                access_key=MINIO_CONFIG['access_key'],
                secret_key=MINIO_CONFIG['secret_key'],
                secure=MINIO_CONFIG['secure']
            )
            self.logger.info(f"MinIO client initialized for symbol: {self.symbol}")
            return client
        except Exception as e:
            self.logger.error(f"Failed to initialize MinIO client: {str(e)}")
            raise

    def _ensure_bucket_exists(self) -> None:
        """Create bucket if it doesn't exist."""
        bucket_name = MINIO_CONFIG['raw_bucket']
        try:
            if not self.minio_client.bucket_exists(bucket_name):
                self.minio_client.make_bucket(bucket_name)
                self.logger.info(f"Created bucket: {bucket_name}")
            else:
                self.logger.debug(f"Bucket {bucket_name} already exists")
        except S3Error as e:
            self.logger.error(f"Error with bucket operations: {str(e)}")
            raise

    def fetch_data_in_batches(
        self,
        interval: str = None,
        total_limit: int = None,
        batch_size: int = None
    ) -> Iterator[List]:
        """
        Generator that yields batches one at a time - memory efficient.

        Args:
            interval: Kline interval (default: 15m)
            total_limit: Total records to fetch
            batch_size: Records per batch

        Yields:
            List of kline data
        """
        interval = interval or BINANCE_CONFIG['interval']
        total_limit = total_limit or BINANCE_CONFIG['total_limit']
        batch_size = batch_size or BINANCE_CONFIG['batch_size']

        try:
            num_batches = (total_limit + batch_size - 1) // batch_size
            self.logger.info(
                f"Fetching {total_limit} records for {self.symbol} in {num_batches} batches"
            )

            records_fetched = 0
            last_timestamp = None

            for batch_num in range(num_batches):
                current_batch_limit = min(batch_size, total_limit - records_fetched)

                if current_batch_limit <= 0:
                    break

                params = {
                    'symbol': self.symbol,
                    'interval': interval,
                    'limit': current_batch_limit
                }

                # Use last timestamp for pagination
                if last_timestamp:
                    params['endTime'] = last_timestamp - 1

                # Rate limiting
                if self.request_count % 100 == 0 and self.request_count > 0:
                    time.sleep(1)
                    self.logger.info(f"Rate limiting pause after {self.request_count} requests")

                self.request_count += 1

                try:
                    response = self.session.get(
                        self.base_url,
                        params=params,
                        timeout=(10, 30)
                    )
                except Exception as e:
                    if "Failed to resolve" in str(e) or "Max retries exceeded" in str(e):
                        self.logger.warning(f"Connection issue, resetting session: {e}")
                        self.session.close()
                        self.session = self._create_session()
                        time.sleep(2)
                        response = self.session.get(
                            self.base_url,
                            params=params,
                            timeout=(10, 30)
                        )
                    else:
                        raise

                if response.status_code == 200:
                    batch_data = response.json()

                    if not batch_data:
                        break

                    last_timestamp = min(int(record[0]) for record in batch_data)
                    records_fetched += len(batch_data)

                    self.logger.info(f"Batch {batch_num + 1}: Fetched {len(batch_data)} records")

                    yield batch_data

                    if len(batch_data) < current_batch_limit:
                        break
                else:
                    raise Exception(f"API returned status code: {response.status_code}")

        except Exception as e:
            self.logger.error(f"Failed to fetch data for {self.symbol}: {str(e)}")
            raise

    def save_raw_data(
        self,
        batch_data: List,
        batch_number: int,
        total_batches: int = None
    ) -> Dict[str, Any]:
        """Save raw JSON data to MinIO with proper batch identification."""
        bucket_name = MINIO_CONFIG['raw_bucket']
        date_str = datetime.now().strftime("%Y-%m-%d")
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

        if total_batches:
            batch_id = f"{self.symbol}_{timestamp}_{batch_number:03d}_of_{total_batches:03d}"
        else:
            batch_id = f"{self.symbol}_{timestamp}_{batch_number:03d}"

        object_key = f"date={date_str}/symbol={self.symbol}/batch_{batch_number:03d}.json"

        metadata = {
            'symbol': self.symbol,
            'extraction_time': datetime.now().isoformat(),
            'record_count': len(batch_data),
            'batch_id': batch_id,
            'batch_number': batch_number,
            'total_batches': total_batches,
            'object_key': object_key,
            'bucket': bucket_name
        }

        upload_data = {
            'metadata': metadata,
            'data': batch_data
        }

        try:
            json_bytes = json.dumps(upload_data, indent=2).encode('utf-8')
            json_stream = BytesIO(json_bytes)

            self.minio_client.put_object(
                bucket_name=bucket_name,
                object_name=object_key,
                data=json_stream,
                length=len(json_bytes),
                content_type='application/json'
            )

            batch_info = f"batch {batch_number}"
            if total_batches:
                batch_info += f" of {total_batches}"

            self.logger.info(f"Saved {len(batch_data)} records to MinIO: {object_key} ({batch_info})")
            return metadata

        except S3Error as e:
            self.logger.error(f"Failed to save data to MinIO: {str(e)}")
            raise

    def __del__(self):
        """Cleanup session when object is destroyed."""
        if hasattr(self, 'session'):
            self.session.close()


def extract_symbol_data(symbol: str, **context) -> Dict[str, Any]:
    """
    Airflow task function to extract data for a symbol.

    Args:
        symbol: Trading pair symbol (e.g., BTCUSDT)

    Returns:
        Extraction result dictionary
    """
    extractor = MinIODataExtractor(symbol)

    try:
        all_metadata = []
        batch_number = 0
        total_records = 0

        for batch_data in extractor.fetch_data_in_batches():
            batch_number += 1

            metadata = extractor.save_raw_data(
                batch_data,
                batch_number=batch_number,
                total_batches=None
            )

            all_metadata.append(metadata)
            total_records += len(batch_data)

            del batch_data

        for meta in all_metadata:
            meta['total_batches'] = batch_number

        return {
            'symbol': symbol,
            'status': 'success',
            'total_batches': batch_number,
            'total_records': total_records,
            'batch_metadata': all_metadata
        }

    except Exception as e:
        logging.error(f"Extraction failed for {symbol}: {str(e)}")
        return {
            'symbol': symbol,
            'status': 'failed',
            'error': str(e)
        }

"""
Data Loader Module

Loads data from MinIO to PostgreSQL.
Adapted from data-engineering-course-yt for ml-eng-with-ops.
"""

import json
import logging
from datetime import datetime
from io import BytesIO
from typing import Dict, Any, List, Optional

import psycopg2
from psycopg2.extras import execute_batch
from minio import Minio
from minio.error import S3Error

from .config import DB_CONFIG, MINIO_CONFIG, SYMBOLS


class PostgreSQLLoader:
    """Load batch data from MinIO to PostgreSQL."""

    def __init__(self, symbol: str, batch_number: int):
        self.symbol = symbol
        self.batch_number = batch_number
        self.logger = logging.getLogger(f"loader_{symbol}_batch_{batch_number}")
        self.minio_client = self._get_minio_client()

    def _get_minio_client(self) -> Minio:
        """Initialize MinIO client."""
        try:
            client = Minio(
                MINIO_CONFIG['endpoint'],
                access_key=MINIO_CONFIG['access_key'],
                secret_key=MINIO_CONFIG['secret_key'],
                secure=MINIO_CONFIG['secure']
            )
            self.logger.debug(f"MinIO client initialized for {self.symbol}")
            return client
        except Exception as e:
            self.logger.error(f"Failed to initialize MinIO client: {str(e)}")
            raise

    def _get_db_connection(self):
        """Get database connection."""
        try:
            conn = psycopg2.connect(**DB_CONFIG)
            return conn
        except psycopg2.Error as e:
            self.logger.error(f"Database connection failed: {str(e)}")
            raise

    def _create_table_if_not_exists(self, conn) -> None:
        """Create crypto_data table if it doesn't exist."""
        cursor = conn.cursor()

        try:
            cursor.execute("""
                SELECT EXISTS (
                    SELECT 1 FROM pg_tables
                    WHERE schemaname = 'public' AND tablename = 'crypto_data'
                );
            """)
            table_exists = cursor.fetchone()[0]

            if not table_exists:
                create_table_query = """
                CREATE TABLE IF NOT EXISTS crypto_data (
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
                    trades_count INTEGER NOT NULL,
                    buy_ratio REAL,
                    batch_id TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(symbol, open_time)
                );

                -- Create indexes for common queries
                CREATE INDEX IF NOT EXISTS idx_crypto_data_symbol ON crypto_data(symbol);
                CREATE INDEX IF NOT EXISTS idx_crypto_data_open_time ON crypto_data(open_time);
                CREATE INDEX IF NOT EXISTS idx_crypto_data_symbol_time ON crypto_data(symbol, open_time DESC);
                """
                cursor.execute(create_table_query)
                conn.commit()
                self.logger.info("Table 'crypto_data' created with indexes")
            else:
                self.logger.debug("Table 'crypto_data' already exists")

        except Exception as e:
            self.logger.error(f"Error creating/checking table: {e}")
            conn.rollback()
            raise
        finally:
            cursor.close()

    def read_batch_from_minio(self, date_str: str = None) -> Dict:
        """Read batch data from MinIO."""
        date_str = date_str or datetime.now().strftime("%Y-%m-%d")
        bucket_name = MINIO_CONFIG['raw_bucket']
        object_key = f"date={date_str}/symbol={self.symbol}/batch_{self.batch_number:03d}.json"

        try:
            response = self.minio_client.get_object(bucket_name, object_key)
            data = json.loads(response.read().decode('utf-8'))
            self.logger.info(f"Read batch from MinIO: {object_key}")
            return data

        except S3Error as e:
            self.logger.error(f"Failed to read from MinIO: {str(e)}")
            raise

    def transform_data(self, raw_data: Dict) -> List[Dict]:
        """Transform raw Binance kline data for database insertion."""
        transformed_records = []

        for kline in raw_data['data']:
            # Binance kline format:
            # [open_time, open, high, low, close, volume, close_time,
            #  quote_volume, count, taker_buy_volume, taker_buy_quote_volume, ignore]

            volume = float(kline[5])
            taker_buy_volume = float(kline[9])
            buy_ratio = round(taker_buy_volume / volume * 100, 4) if volume > 0 else 0.0

            record = {
                'symbol': self.symbol,
                'open_time': int(kline[0]),
                'close_time': int(kline[6]),
                'open_price': float(kline[1]),
                'high_price': float(kline[2]),
                'low_price': float(kline[3]),
                'close_price': float(kline[4]),
                'volume': float(kline[5]),
                'quote_volume': float(kline[7]),
                'trades_count': int(kline[8]),
                'buy_ratio': buy_ratio,
                'batch_id': f"{self.symbol}_{self.batch_number}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
            }

            transformed_records.append(record)

        self.logger.info(f"Transformed {len(transformed_records)} records for {self.symbol}")
        return transformed_records

    def bulk_insert_records(self, records: List[Dict]) -> Dict[str, Any]:
        """Bulk insert records into PostgreSQL using execute_batch."""
        insert_sql = """
        INSERT INTO crypto_data (
            symbol, open_time, close_time, open_price, high_price, low_price,
            close_price, volume, quote_volume, trades_count, buy_ratio, batch_id
        ) VALUES (
            %(symbol)s, %(open_time)s, %(close_time)s, %(open_price)s, %(high_price)s, %(low_price)s,
            %(close_price)s, %(volume)s, %(quote_volume)s, %(trades_count)s, %(buy_ratio)s, %(batch_id)s
        ) ON CONFLICT (symbol, open_time) DO UPDATE SET
            close_time = EXCLUDED.close_time,
            open_price = EXCLUDED.open_price,
            high_price = EXCLUDED.high_price,
            low_price = EXCLUDED.low_price,
            close_price = EXCLUDED.close_price,
            volume = EXCLUDED.volume,
            quote_volume = EXCLUDED.quote_volume,
            trades_count = EXCLUDED.trades_count,
            buy_ratio = EXCLUDED.buy_ratio,
            batch_id = EXCLUDED.batch_id,
            created_at = CURRENT_TIMESTAMP
        """

        conn = None
        try:
            conn = self._get_db_connection()
            self._create_table_if_not_exists(conn)

            with conn.cursor() as cursor:
                execute_batch(
                    cursor,
                    insert_sql,
                    records,
                    page_size=1000
                )
                conn.commit()

                self.logger.info(f"Successfully inserted {len(records)} records for {self.symbol}")

                return {
                    'symbol': self.symbol,
                    'batch_number': self.batch_number,
                    'records_processed': len(records),
                    'status': 'success',
                    'processing_time': datetime.now().isoformat()
                }

        except psycopg2.Error as e:
            if conn:
                conn.rollback()
            self.logger.error(f"Database error during bulk insert: {str(e)}")
            raise
        finally:
            if conn:
                conn.close()

    def process_batch(self) -> Dict[str, Any]:
        """Main method to process a batch from MinIO to PostgreSQL."""
        try:
            raw_data = self.read_batch_from_minio()
            transformed_records = self.transform_data(raw_data)
            result = self.bulk_insert_records(transformed_records)
            return result

        except Exception as e:
            self.logger.error(
                f"Batch processing failed for {self.symbol} batch {self.batch_number}: {str(e)}"
            )
            return {
                'symbol': self.symbol,
                'batch_number': self.batch_number,
                'status': 'failed',
                'error': str(e),
                'processing_time': datetime.now().isoformat()
            }


def discover_batches(**context) -> List[Dict]:
    """Discover all batch files that need processing."""
    minio_client = Minio(
        MINIO_CONFIG['endpoint'],
        access_key=MINIO_CONFIG['access_key'],
        secret_key=MINIO_CONFIG['secret_key'],
        secure=MINIO_CONFIG['secure']
    )

    bucket_name = MINIO_CONFIG['raw_bucket']
    date_str = datetime.now().strftime("%Y-%m-%d")
    batches_to_process = []

    try:
        objects = minio_client.list_objects(
            bucket_name,
            prefix=f"date={date_str}/",
            recursive=True
        )

        for obj in objects:
            if obj.object_name.endswith('.json') and 'batch_' in obj.object_name:
                parts = obj.object_name.split('/')
                if len(parts) >= 3:
                    symbol_part = parts[1]
                    batch_part = parts[2]

                    symbol = symbol_part.split('=')[1]
                    batch_number = int(batch_part.split('_')[1].split('.')[0])

                    batches_to_process.append({
                        'symbol': symbol,
                        'batch_number': batch_number,
                        'object_key': obj.object_name
                    })

        logging.info(f"Discovered {len(batches_to_process)} batches to process")
        return batches_to_process

    except Exception as e:
        logging.error(f"Failed to discover batches: {str(e)}")
        raise


def process_symbol_batches(symbol: str, **context) -> Dict[str, Any]:
    """Process all batches for a specific symbol."""
    task_instance = context['task_instance']

    all_discovered_batches = task_instance.xcom_pull(
        task_ids='loading_group.discover_batches'
    )

    if not all_discovered_batches:
        logging.warning("No batches discovered for processing")
        return {
            'symbol': symbol,
            'total_batches': 0,
            'processed_batches': 0,
            'failed_batches': 0,
            'batch_results': []
        }

    symbol_batches = [b for b in all_discovered_batches if b['symbol'] == symbol]

    if not symbol_batches:
        logging.warning(f"No batches found for symbol: {symbol}")
        return {
            'symbol': symbol,
            'total_batches': 0,
            'processed_batches': 0,
            'failed_batches': 0,
            'batch_results': []
        }

    logging.info(f"Processing {len(symbol_batches)} batches for symbol: {symbol}")

    all_results = []
    successful_count = 0
    failed_count = 0
    total_records = 0

    symbol_batches.sort(key=lambda x: x['batch_number'])

    for batch_info in symbol_batches:
        batch_number = batch_info['batch_number']

        try:
            logging.info(f"Processing {symbol} batch {batch_number}")

            loader = PostgreSQLLoader(symbol, batch_number)
            result = loader.process_batch()

            if result['status'] == 'success':
                successful_count += 1
                total_records += result.get('records_processed', 0)
            else:
                failed_count += 1

            all_results.append(result)

        except Exception as e:
            failed_count += 1
            error_result = {
                'symbol': symbol,
                'batch_number': batch_number,
                'status': 'failed',
                'error': str(e),
                'processing_time': datetime.now().isoformat()
            }
            all_results.append(error_result)
            logging.error(f"Exception processing {symbol} batch {batch_number}: {str(e)}")

    return {
        'symbol': symbol,
        'total_batches': len(symbol_batches),
        'processed_batches': successful_count,
        'failed_batches': failed_count,
        'total_records_processed': total_records,
        'batch_results': all_results,
        'processing_time': datetime.now().isoformat()
    }


def collect_loading_results(symbols: List[str], **context) -> Dict[str, Any]:
    """Collect results from all symbol loading tasks."""
    task_instance = context['task_instance']

    all_symbol_results = []
    overall_stats = {
        'total_symbols': len(symbols),
        'total_batches': 0,
        'successful_batches': 0,
        'failed_batches': 0,
        'total_records_processed': 0
    }

    for symbol in symbols:
        task_id = f'loading_group.load_{symbol.lower()}'
        symbol_result = task_instance.xcom_pull(task_ids=task_id)

        if symbol_result:
            all_symbol_results.append(symbol_result)
            overall_stats['total_batches'] += symbol_result.get('total_batches', 0)
            overall_stats['successful_batches'] += symbol_result.get('processed_batches', 0)
            overall_stats['failed_batches'] += symbol_result.get('failed_batches', 0)
            overall_stats['total_records_processed'] += symbol_result.get('total_records_processed', 0)
        else:
            logging.warning(f"No result found for symbol: {symbol}")

    final_summary = {
        'processing_time': datetime.now().isoformat(),
        'overall_stats': overall_stats,
        'symbol_results': all_symbol_results
    }

    logging.info(
        f"Overall Loading Summary: {overall_stats['successful_batches']}/{overall_stats['total_batches']} "
        f"batches successful, {overall_stats['total_records_processed']} total records"
    )

    # Save summary to MinIO
    try:
        minio_client = Minio(
            MINIO_CONFIG['endpoint'],
            access_key=MINIO_CONFIG['access_key'],
            secret_key=MINIO_CONFIG['secret_key'],
            secure=MINIO_CONFIG['secure']
        )

        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        summary_key = f"loading_summaries/loading_summary_{timestamp}.json"

        json_bytes = json.dumps(final_summary, indent=2).encode('utf-8')
        json_stream = BytesIO(json_bytes)

        minio_client.put_object(
            bucket_name=MINIO_CONFIG['raw_bucket'],
            object_name=summary_key,
            data=json_stream,
            length=len(json_bytes),
            content_type='application/json'
        )

        logging.info(f"Loading summary saved to MinIO: {summary_key}")

    except Exception as e:
        logging.error(f"Failed to save loading summary: {str(e)}")

    return final_summary

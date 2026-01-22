"""
ETL Pipeline DAG

Extracts crypto OHLCV data from Binance API and loads into PostgreSQL.
Schedule: Hourly

Pipeline Stages:
1. Pre-checks: Validate API, database, and system resources
2. Extraction: Fetch data from Binance and store in MinIO
3. Loading: Transform and load from MinIO to PostgreSQL
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.operators.empty import EmptyOperator
from airflow.utils.task_group import TaskGroup
from airflow.utils.trigger_rule import TriggerRule

import sys
import os

# Add dags directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from etl.config import SYMBOLS
from etl.pre_checks import run_prechecks
from etl.extraction import extract_symbol_data
from etl.loader import (
    discover_batches,
    process_symbol_batches,
    collect_loading_results
)

# DAG default arguments
default_args = {
    'owner': 'ml-pipeline',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 1),
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
    'execution_timeout': timedelta(hours=2),
    'email_on_failure': False,
    'email_on_retry': False,
}

# Create the DAG
with DAG(
    dag_id='etl_crypto_data_pipeline',
    default_args=default_args,
    description='ETL Pipeline: Binance API → MinIO → PostgreSQL',
    schedule='@hourly',
    catchup=False,
    tags=['etl', 'crypto', 'binance', 'production'],
    max_active_runs=1,
    doc_md="""
    # Crypto ETL Pipeline

    ## Overview
    Extracts OHLCV data from Binance API for 10 crypto symbols and loads into PostgreSQL.

    ## Stages
    1. **Pre-checks**: Validate API, database, MinIO, and system resources
    2. **Extraction**: Fetch 300K records per symbol in batches, store in MinIO
    3. **Loading**: Transform and bulk insert into PostgreSQL

    ## Symbols
    BTCUSDT, ETHUSDT, BNBUSDT, ADAUSDT, SOLUSDT, XRPUSDT, DOTUSDT, AVAXUSDT, MATICUSDT, LINKUSDT

    ## Data Volume
    - ~300K records per symbol
    - ~3M records total per run
    - 15-minute interval candles
    """
) as dag:

    # Start marker
    start = EmptyOperator(task_id='start')

    # Stage 1: Pre-checks
    prechecks = PythonOperator(
        task_id='etl_prechecks',
        python_callable=run_prechecks,
        doc_md="Run pre-flight checks for API, database, and system resources"
    )

    # Stage 2: Data Extraction
    with TaskGroup("extraction_group", tooltip="Extract data from Binance API") as extraction_group:
        extraction_tasks = []

        for symbol in SYMBOLS:
            task = PythonOperator(
                task_id=f'extract_{symbol.lower()}',
                python_callable=extract_symbol_data,
                op_args=[symbol],
                pool='binance_api_pool',  # Limit concurrent API calls
                doc_md=f"Extract OHLCV data for {symbol}"
            )
            extraction_tasks.append(task)

        # Extraction completion marker
        extraction_complete = EmptyOperator(
            task_id='extraction_complete',
            trigger_rule=TriggerRule.ALL_SUCCESS
        )

        extraction_tasks >> extraction_complete

    # Stage 3: Data Loading
    with TaskGroup("loading_group", tooltip="Load data to PostgreSQL") as loading_group:

        # Discover batches
        discover = PythonOperator(
            task_id='discover_batches',
            python_callable=discover_batches,
            doc_md="Discover all batches in MinIO that need processing"
        )

        # Load each symbol
        loading_tasks = []
        for symbol in SYMBOLS:
            task = PythonOperator(
                task_id=f'load_{symbol.lower()}',
                python_callable=process_symbol_batches,
                op_args=[symbol],
                pool='postgres_pool',  # Limit concurrent DB connections
                doc_md=f"Load {symbol} data to PostgreSQL"
            )
            loading_tasks.append(task)

        # Collect results
        collect_results = PythonOperator(
            task_id='collect_results',
            python_callable=collect_loading_results,
            op_args=[SYMBOLS],
            trigger_rule=TriggerRule.ALL_DONE,
            doc_md="Collect and summarize loading results"
        )

        discover >> loading_tasks >> collect_results

    # End marker
    end = EmptyOperator(
        task_id='end',
        trigger_rule=TriggerRule.ALL_DONE
    )

    # Set dependencies
    start >> prechecks >> extraction_group >> loading_group >> end

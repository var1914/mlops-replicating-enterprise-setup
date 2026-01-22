"""
ML Training Pipeline DAG

Trains ML models on crypto data and registers to MLflow.
Schedule: Daily at 2 AM (after ETL completes)

Pipeline Stages:
1. Data Validation: Validate data quality for training
2. Feature Engineering: Generate 80+ technical indicators
3. Model Training: Train LightGBM and XGBoost models
4. Model Promotion: Promote best models to staging/production
5. API Reload: Trigger inference API to load new models
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.standard.operators.python import PythonOperator
from airflow.providers.standard.operators.empty import EmptyOperator
from airflow.utils.task_group import TaskGroup
from airflow.utils.trigger_rule import TriggerRule

import sys
import os
import logging

# Add dags directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from etl.config import SYMBOLS, MLFLOW_CONFIG

# DAG default arguments
default_args = {
    'owner': 'ml-pipeline',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 1),
    'retries': 1,
    'retry_delay': timedelta(minutes=10),
    'execution_timeout': timedelta(hours=4),
    'email_on_failure': False,
    'email_on_retry': False,
}


def run_data_validation(symbols: list, **context) -> dict:
    """Run data validation for training readiness."""
    from automated_data_validation import DataValidationSuite

    results = {}
    for symbol in symbols:
        try:
            validator = DataValidationSuite(symbol)
            validation_result = validator.run_all_validations()
            results[symbol] = {
                'status': 'passed' if validation_result.get('is_valid', False) else 'failed',
                'details': validation_result
            }
        except Exception as e:
            logging.error(f"Validation failed for {symbol}: {e}")
            results[symbol] = {'status': 'error', 'error': str(e)}

    return results


def run_feature_engineering(symbol: str, **context) -> dict:
    """Run feature engineering for a symbol."""
    from feature_eng import FeatureEngineeringPipeline
    from etl.config import DB_CONFIG

    try:
        pipeline = FeatureEngineeringPipeline(DB_CONFIG)
        result = pipeline.run_feature_pipeline([symbol], create_targets=True)

        return {
            'symbol': symbol,
            'status': 'success',
            'features_generated': result.get('features_count', 0),
            'targets_created': result.get('targets_created', False)
        }

    except Exception as e:
        logging.error(f"Feature engineering failed for {symbol}: {e}")
        return {
            'symbol': symbol,
            'status': 'failed',
            'error': str(e)
        }


def train_models_for_symbol(symbol: str, **context) -> dict:
    """Train all models for a symbol."""
    from model_training import ModelTrainingPipeline

    try:
        pipeline = ModelTrainingPipeline()

        # Train models for this symbol
        results = pipeline.train_symbol_models(
            symbol=symbol,
            tasks_to_train=['return_4step', 'direction_4step', 'volatility_4step'],
            model_types=['lightgbm', 'xgboost']
        )

        return {
            'symbol': symbol,
            'status': 'success',
            'models_trained': len(results.get('models', [])),
            'best_metrics': results.get('best_metrics', {})
        }

    except Exception as e:
        logging.error(f"Training failed for {symbol}: {e}")
        return {
            'symbol': symbol,
            'status': 'failed',
            'error': str(e)
        }


def promote_best_models(**context) -> dict:
    """Promote best models to staging and production."""
    from model_promotion import ModelPromotion

    try:
        promoter = ModelPromotion()

        # Promote best models to staging
        staging_results = promoter.promote_models_to_staging()

        # Auto-promote to production if metrics meet threshold
        production_results = promoter.automated_promotion_with_validation()

        return {
            'status': 'success',
            'staging_promoted': staging_results.get('promoted_count', 0),
            'production_promoted': production_results.get('promoted_count', 0)
        }

    except Exception as e:
        logging.error(f"Model promotion failed: {e}")
        return {
            'status': 'failed',
            'error': str(e)
        }


def reload_inference_api(**context) -> dict:
    """Trigger inference API to reload models."""
    import requests
    from etl.config import ETL_CONFIG

    api_url = os.getenv('INFERENCE_API_URL', 'http://crypto-prediction-api:8000')

    try:
        response = requests.post(f"{api_url}/models/reload", timeout=30)

        if response.status_code == 200:
            return {
                'status': 'success',
                'message': 'API models reloaded successfully'
            }
        else:
            return {
                'status': 'failed',
                'message': f'API returned status {response.status_code}'
            }

    except Exception as e:
        logging.error(f"Failed to reload API: {e}")
        return {
            'status': 'failed',
            'error': str(e)
        }


def collect_training_results(**context) -> dict:
    """Collect and summarize all training results."""
    task_instance = context['task_instance']

    results = {
        'symbols_trained': [],
        'symbols_failed': [],
        'total_models': 0
    }

    for symbol in SYMBOLS:
        task_id = f'training_group.train_{symbol.lower()}'
        result = task_instance.xcom_pull(task_ids=task_id)

        if result and result.get('status') == 'success':
            results['symbols_trained'].append(symbol)
            results['total_models'] += result.get('models_trained', 0)
        else:
            results['symbols_failed'].append(symbol)

    results['success_rate'] = len(results['symbols_trained']) / len(SYMBOLS) * 100

    logging.info(f"Training Summary: {len(results['symbols_trained'])}/{len(SYMBOLS)} symbols successful")

    return results


# Create the DAG
with DAG(
    dag_id='ml_training_pipeline',
    default_args=default_args,
    description='ML Training Pipeline: Feature Engineering → Training → Deployment',
    schedule='0 2 * * *',  # Daily at 2 AM
    catchup=False,
    tags=['ml', 'training', 'mlflow', 'production'],
    max_active_runs=1,
    doc_md="""
    # ML Training Pipeline

    ## Overview
    Trains ML models for crypto price prediction and deploys to production.

    ## Stages
    1. **Data Validation**: Check data quality and training readiness
    2. **Feature Engineering**: Generate 80+ technical indicators
    3. **Model Training**: Train LightGBM and XGBoost for each symbol
    4. **Model Promotion**: Promote best models to staging/production
    5. **API Reload**: Trigger inference API to load new models

    ## Models
    - Tasks: return_4step, direction_4step, volatility_4step
    - Algorithms: LightGBM, XGBoost

    ## Dependencies
    - Requires ETL pipeline to run first (crypto_data table populated)
    - Requires MLflow for model registry
    - Requires MinIO for feature/model storage
    """
) as dag:

    # Start marker
    start = EmptyOperator(task_id='start')

    # Optional: Wait for ETL to complete (if running same day)
    # wait_for_etl = ExternalTaskSensor(
    #     task_id='wait_for_etl',
    #     external_dag_id='etl_crypto_data_pipeline',
    #     external_task_id='end',
    #     timeout=3600,
    #     mode='reschedule'
    # )

    # Stage 1: Data Validation
    validate_data = PythonOperator(
        task_id='validate_data',
        python_callable=run_data_validation,
        op_args=[SYMBOLS],
        doc_md="Validate data quality for ML training"
    )

    # Stage 2: Feature Engineering
    with TaskGroup("feature_group", tooltip="Feature Engineering") as feature_group:
        feature_tasks = []

        for symbol in SYMBOLS:
            task = PythonOperator(
                task_id=f'features_{symbol.lower()}',
                python_callable=run_feature_engineering,
                op_args=[symbol],
                doc_md=f"Generate features for {symbol}"
            )
            feature_tasks.append(task)

        feature_complete = EmptyOperator(
            task_id='features_complete',
            trigger_rule=TriggerRule.ALL_SUCCESS
        )

        feature_tasks >> feature_complete

    # Stage 3: Model Training
    with TaskGroup("training_group", tooltip="Model Training") as training_group:
        training_tasks = []

        for symbol in SYMBOLS:
            task = PythonOperator(
                task_id=f'train_{symbol.lower()}',
                python_callable=train_models_for_symbol,
                op_args=[symbol],
                pool='ml_training_pool',  # Limit concurrent training
                doc_md=f"Train models for {symbol}"
            )
            training_tasks.append(task)

        collect_results = PythonOperator(
            task_id='collect_results',
            python_callable=collect_training_results,
            trigger_rule=TriggerRule.ALL_DONE,
            doc_md="Collect training results"
        )

        training_tasks >> collect_results

    # Stage 4: Model Promotion
    promote_models = PythonOperator(
        task_id='promote_models',
        python_callable=promote_best_models,
        doc_md="Promote best models to staging/production"
    )

    # Stage 5: API Reload (commented out until inference API is deployed)
    # reload_api = PythonOperator(
    #     task_id='reload_api',
    #     python_callable=reload_inference_api,
    #     doc_md="Trigger inference API to reload models"
    # )

    # End marker
    end = EmptyOperator(
        task_id='end',
        trigger_rule=TriggerRule.ALL_DONE
    )

    # Set dependencies
    start >> validate_data >> feature_group >> training_group >> promote_models >> end

# production_api.py - Production FastAPI service
from fastapi import FastAPI, HTTPException, BackgroundTasks, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional, Dict, Any, Union
from datetime import datetime
import logging
import asyncio
import os
import sys
from contextlib import asynccontextmanager

# Add parent directory to path for imports
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from dags.inference_feature_pipeline import MultiTaskModelPredictor, INFERENCE_TASKS
from src.config import get_settings

# Load configuration
settings = get_settings()

# Configure logging
logging.basicConfig(level=getattr(logging, settings.api.log_level.upper()))
logger = logging.getLogger("prediction_api")

# Global predictor instance
predictor: Optional[MultiTaskModelPredictor] = None

# Configuration from settings
DB_CONFIG = settings.database.get_connection_dict()
REDIS_CONFIG = settings.redis.get_client_config()
SUPPORTED_SYMBOLS = settings.binance.symbols

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage startup and shutdown"""
    # Startup
    global predictor
    try:
        logger.info("Initializing prediction service...")
        predictor = MultiTaskModelPredictor(DB_CONFIG, REDIS_CONFIG)
        
        # Load production models
        loaded, failed = predictor.load_production_models(
            symbols=SUPPORTED_SYMBOLS,
            tasks=list(INFERENCE_TASKS.keys()),
            model_types=['lightgbm', 'xgboost']
        )
        
        logger.info(f"Service initialized: {loaded} models loaded, {failed} failed")
        
    except Exception as e:
        logger.error(f"Failed to initialize predictor: {e}")
        raise
    
    yield
    
    # Shutdown
    logger.info("Shutting down prediction service...")

# Create FastAPI app
app = FastAPI(
    title="Crypto Multi-Task Prediction API",
    description="Real-time cryptocurrency predictions for price, direction, and volatility",
    version="2.0.0",
    lifespan=lifespan
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Pydantic models
class SymbolPredictionRequest(BaseModel):
    symbol: str
    tasks: Optional[List[str]] = None
    timestamp: Optional[datetime] = None

class BatchPredictionRequest(BaseModel):
    symbols: List[str]
    tasks: Optional[List[str]] = None
    timestamp: Optional[datetime] = None

class ModelPromotionRequest(BaseModel):
    model_name: str
    version: str
    stage: str  # "Staging" or "Production"

class PredictionResponse(BaseModel):
    symbol: str
    timestamp: datetime
    features_count: int
    task_predictions: Dict[str, Dict[str, Any]]
    ensemble_predictions: Dict[str, Any]

class HealthResponse(BaseModel):
    status: str
    timestamp: datetime
    loaded_models: int
    available_symbols: List[str]
    model_status: Dict[str, Any]

@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint with detailed model status"""
    if not predictor:
        raise HTTPException(status_code=503, detail="Predictor not initialized")
    
    status = predictor.get_model_status()
    
    return HealthResponse(
        status="healthy",
        timestamp=datetime.now(),
        loaded_models=status['total_models'],
        available_symbols=list(status['models_by_symbol'].keys()),
        model_status=status
    )

@app.get("/tasks")
async def list_available_tasks():
    """List all available prediction tasks"""
    return {
        "tasks": INFERENCE_TASKS,
        "total_tasks": len(INFERENCE_TASKS)
    }

@app.get("/models")
async def list_loaded_models():
    """List all loaded models and their metadata"""
    if not predictor:
        raise HTTPException(status_code=503, detail="Predictor not initialized")
    
    models_info = {}
    for model_key, metadata in predictor.model_metadata.items():
        parts = model_key.split('_')
        symbol = parts[0]
        task = '_'.join(parts[1:-1])
        model_type = parts[-1]
        
        if symbol not in models_info:
            models_info[symbol] = {}
        if task not in models_info[symbol]:
            models_info[symbol][task] = {}
        
        models_info[symbol][task][model_type] = {
            'version': metadata['version'],
            'stage': metadata['stage'],
            'task_type': metadata['task_type'],
            'registered_name': metadata['registered_name']
        }
    
    return {
        'models': models_info,
        'total_models': len(predictor.models),
        'timestamp': datetime.now()
    }

@app.post("/predict/{symbol}", response_model=PredictionResponse)
async def predict_symbol(
    symbol: str,
    tasks: Optional[List[str]] = Query(None, description="Specific tasks to predict"),
    timestamp: Optional[datetime] = Query(None, description="Specific timestamp for prediction")
):
    """Make predictions for a single symbol"""
    if not predictor:
        raise HTTPException(status_code=503, detail="Predictor not initialized")
    
    if symbol not in SUPPORTED_SYMBOLS:
        raise HTTPException(status_code=400, detail=f"Symbol {symbol} not supported")
    
    try:
        # Make predictions for all available tasks
        result = predictor.predict_all_tasks(symbol, timestamp)
        
        if 'error' in result:
            raise HTTPException(status_code=400, detail=result['error'])
        
        # Filter tasks if specified
        if tasks:
            filtered_task_predictions = {
                task: pred for task, pred in result['task_predictions'].items()
                if task in tasks
            }
            filtered_ensemble_predictions = {
                task: pred for task, pred in result['ensemble_predictions'].items()
                if task in tasks
            }
            result['task_predictions'] = filtered_task_predictions
            result['ensemble_predictions'] = filtered_ensemble_predictions
        
        return PredictionResponse(**result)
        
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.error(f"Prediction error for {symbol}: {e}")
        raise HTTPException(status_code=500, detail="Prediction failed")

@app.post("/predict/batch")
async def predict_batch(request: BatchPredictionRequest):
    """Make predictions for multiple symbols"""
    if not predictor:
        raise HTTPException(status_code=503, detail="Predictor not initialized")
    
    # Validate symbols
    unsupported = [s for s in request.symbols if s not in SUPPORTED_SYMBOLS]
    if unsupported:
        raise HTTPException(
            status_code=400, 
            detail=f"Unsupported symbols: {unsupported}"
        )
    
    try:
        results = {}
        for symbol in request.symbols:
            try:
                result = predictor.predict_all_tasks(symbol, request.timestamp)
                
                # Filter tasks if specified
                if request.tasks:
                    filtered_task_predictions = {
                        task: pred for task, pred in result['task_predictions'].items()
                        if task in request.tasks
                    }
                    filtered_ensemble_predictions = {
                        task: pred for task, pred in result['ensemble_predictions'].items()
                        if task in request.tasks
                    }
                    result['task_predictions'] = filtered_task_predictions
                    result['ensemble_predictions'] = filtered_ensemble_predictions
                
                results[symbol] = result
                
            except Exception as e:
                logger.error(f"Batch prediction failed for {symbol}: {e}")
                results[symbol] = {'error': str(e)}
        
        return {
            'batch_timestamp': request.timestamp or datetime.now(),
            'results': results,
            'symbols_processed': len([r for r in results.values() if 'error' not in r]),
            'symbols_failed': len([r for r in results.values() if 'error' in r])
        }
        
    except Exception as e:
        logger.error(f"Batch prediction error: {e}")
        raise HTTPException(status_code=500, detail="Batch prediction failed")

@app.get("/predict/{symbol}/task/{task}")
async def predict_single_task(
    symbol: str, 
    task: str,
    timestamp: Optional[datetime] = Query(None)
):
    """Get prediction for a specific symbol and task"""
    if task not in INFERENCE_TASKS:
        raise HTTPException(status_code=400, detail=f"Task {task} not supported")
    
    # Get all predictions and filter
    result = await predict_symbol(symbol, tasks=[task], timestamp=timestamp)
    
    if task in result.ensemble_predictions:
        return {
            'symbol': symbol,
            'task': task,
            'task_description': INFERENCE_TASKS[task]['description'],
            'prediction': result.ensemble_predictions[task],
            'timestamp': result.timestamp
        }
    else:
        raise HTTPException(status_code=404, detail=f"No prediction available for {symbol}/{task}")

@app.get("/predict/{symbol}/summary")
async def prediction_summary(symbol: str):
    """Get a summary of key predictions for a symbol"""
    result = await predict_symbol(symbol)
    
    # Extract key predictions
    summary = {
        'symbol': symbol,
        'timestamp': result.timestamp,
        'key_predictions': {}
    }
    
    # Price predictions
    for horizon in ['1step', '4step', '16step']:
        task = f'return_{horizon}'
        if task in result.ensemble_predictions:
            pred = result.ensemble_predictions[task]
            horizon_desc = {'1step': '15min', '4step': '1hour', '16step': '4hour'}[horizon]
            summary['key_predictions'][f'price_{horizon_desc}'] = {
                'return_prediction': pred['prediction'],
                'confidence': pred['confidence']
            }
    
    # Direction prediction
    if 'direction_4step' in result.ensemble_predictions:
        direction_pred = result.ensemble_predictions['direction_4step']
        summary['key_predictions']['direction_1hour'] = {
            'direction': 'UP' if direction_pred['class_prediction'] == 1 else 'DOWN',
            'probability': direction_pred.get('probability', direction_pred.get('confidence', 0.5))
        }
    
    # Volatility prediction
    if 'volatility_4step' in result.ensemble_predictions:
        vol_pred = result.ensemble_predictions['volatility_4step']
        summary['key_predictions']['volatility_1hour'] = {
            'volatility': vol_pred['prediction'],
            'confidence': vol_pred['confidence']
        }
    
    return summary

@app.post("/models/reload")
async def reload_models(background_tasks: BackgroundTasks):
    """Reload all models from MLflow registry"""
    if not predictor:
        raise HTTPException(status_code=503, detail="Predictor not initialized")
    
    def reload_task():
        try:
            # Clear current models
            predictor.models.clear()
            predictor.model_metadata.clear()
            
            # Reload
            loaded, failed = predictor.load_production_models(
                symbols=SUPPORTED_SYMBOLS,
                tasks=list(INFERENCE_TASKS.keys()),
                model_types=['lightgbm', 'xgboost']
            )
            
            logger.info(f"Model reload complete: {loaded} loaded, {failed} failed")
            
        except Exception as e:
            logger.error(f"Model reload failed: {e}")
    
    background_tasks.add_task(reload_task)
    
    return {
        'message': 'Model reload started in background',
        'timestamp': datetime.now()
    }

@app.post("/models/promote")
async def promote_model(request: ModelPromotionRequest):
    """Promote a model to a different stage"""
    if not predictor:
        raise HTTPException(status_code=503, detail="Predictor not initialized")
    
    try:
        registry = predictor.mlflow_registry
        
        if request.stage == "Staging":
            version = registry.promote_model_to_staging(request.model_name, request.version)
        elif request.stage == "Production":
            version = registry.promote_model_to_production(request.model_name, request.version)
        else:
            raise HTTPException(status_code=400, detail="Stage must be 'Staging' or 'Production'")
        
        return {
            'message': f'Model {request.model_name} promoted to {request.stage}',
            'model_name': request.model_name,
            'version': version,
            'stage': request.stage,
            'timestamp': datetime.now()
        }
        
    except Exception as e:
        logger.error(f"Model promotion failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/features/{symbol}")
async def get_current_features(symbol: str):
    """Get current feature values for a symbol (debugging)"""
    if not predictor:
        raise HTTPException(status_code=503, detail="Predictor not initialized")
    
    try:
        features = predictor.feature_engine.get_inference_features(symbol)
        
        return {
            'symbol': symbol,
            'features': features,
            'feature_count': len(features),
            'timestamp': datetime.now()
        }
        
    except Exception as e:
        logger.error(f"Feature extraction error for {symbol}: {e}")
        raise HTTPException(status_code=500, detail="Feature extraction failed")

@app.get("/")
async def root():
    """API root with basic information"""
    return {
        "name": "Crypto Multi-Task Prediction API",
        "version": "2.0.0",
        "description": "Real-time predictions for crypto price, direction, and volatility",
        "supported_symbols": SUPPORTED_SYMBOLS,
        "available_tasks": list(INFERENCE_TASKS.keys()),
        "endpoints": {
            "health": "/health",
            "predict_single": "/predict/{symbol}",
            "predict_batch": "/predict/batch",
            "predict_task": "/predict/{symbol}/task/{task}",
            "summary": "/predict/{symbol}/summary",
            "models": "/models",
            "features": "/features/{symbol}"
        }
    }

if __name__ == "__main__":
    import uvicorn
    
    port = int(os.getenv('PORT', '8000'))
    host = os.getenv('HOST', '0.0.0.0')
    
    uvicorn.run(
        app, 
        host=host, 
        port=port,
        log_level="info"
    )
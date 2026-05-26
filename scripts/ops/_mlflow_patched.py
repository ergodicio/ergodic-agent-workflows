"""
Patched MLflow module — changes the REST API path prefix from /api/2.0 to /ajax-api/2.0.

The continuum.ergodic.io tracking server is served behind a reverse proxy that
exposes the API under /ajax-api/2.0/ rather than the upstream default
/api/2.0/. Bare `import mlflow` therefore hits 404s on every REST call.

Usage:
    import _mlflow_patched as mlflow
    client = mlflow.MlflowClient()

Mirrors adept/adept/patched_mlflow.py — keep in sync if upstream changes.
"""

import mlflow.utils.rest_utils

mlflow.utils.rest_utils._REST_API_PATH_PREFIX = "/ajax-api/2.0"
mlflow.utils.rest_utils._TRACE_REST_API_PATH_PREFIX = "/ajax-api/2.0/mlflow/traces"

from mlflow.protos.service_pb2 import MlflowService
from mlflow.store.tracking.rest_store import RestStore
from mlflow.utils.rest_utils import extract_api_info_for_service

RestStore._METHOD_TO_INFO = extract_api_info_for_service(MlflowService, "/ajax-api/2.0")

import mlflow

__all__ = [name for name in dir(mlflow) if not name.startswith("_")]
for name in __all__:
    globals()[name] = getattr(mlflow, name)
__version__ = mlflow.__version__
__doc__ = mlflow.__doc__

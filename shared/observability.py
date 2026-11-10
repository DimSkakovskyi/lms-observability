from __future__ import annotations

import json
import logging
import os
import sys
import time
from datetime import UTC, datetime
from typing import Any

from fastapi import FastAPI, Request, Response
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from starlette.middleware.base import BaseHTTPMiddleware


_STANDARD_LOG_FIELDS = {
    "args",
    "asctime",
    "created",
    "exc_info",
    "exc_text",
    "filename",
    "funcName",
    "levelname",
    "levelno",
    "lineno",
    "message",
    "module",
    "msecs",
    "msg",
    "name",
    "pathname",
    "process",
    "processName",
    "relativeCreated",
    "stack_info",
    "thread",
    "threadName",
    "taskName",
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        context = trace.get_current_span().get_span_context()
        data: dict[str, Any] = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": record.levelname.lower(),
            "service": os.getenv("OTEL_SERVICE_NAME", "unknown-service"),
            "logger": record.name,
            "message": record.getMessage(),
        }
        if context.is_valid:
            data["trace_id"] = format(context.trace_id, "032x")
            data["span_id"] = format(context.span_id, "016x")
        for key, value in record.__dict__.items():
            if key not in _STANDARD_LOG_FIELDS and not key.startswith("_"):
                data[key] = value
        if record.exc_info:
            data["exception"] = self.formatException(record.exc_info)
        return json.dumps(data, default=str, ensure_ascii=False)


def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
    for logger_name in ("uvicorn", "uvicorn.error"):
        logger = logging.getLogger(logger_name)
        logger.handlers.clear()
        logger.propagate = True
    logging.getLogger("uvicorn.access").disabled = True


class MetricsMiddleware(BaseHTTPMiddleware):
    def __init__(
        self,
        app: Any,
        *,
        service_name: str,
        request_counter: Counter,
        request_duration: Histogram,
    ) -> None:
        super().__init__(app)
        self.service_name = service_name
        self.request_counter = request_counter
        self.request_duration = request_duration
        self.logger = logging.getLogger("lms.http")

    async def dispatch(self, request: Request, call_next: Any) -> Response:
        started = time.perf_counter()
        status_code = 500
        try:
            response = await call_next(request)
            status_code = response.status_code
            return response
        finally:
            elapsed = time.perf_counter() - started
            route = request.scope.get("route")
            route_path = getattr(route, "path", "unmatched")
            labels = {
                "service": self.service_name,
                "method": request.method,
                "route": route_path,
                "status": str(status_code),
            }
            self.request_counter.labels(**labels).inc()
            self.request_duration.labels(
                service=self.service_name,
                method=request.method,
                route=route_path,
            ).observe(elapsed)
            if route_path != "/metrics":
                self.logger.info(
                    "request_completed",
                    extra={
                        "http_method": request.method,
                        "http_route": route_path,
                        "http_status": status_code,
                        "duration_ms": round(elapsed * 1000, 2),
                    },
                )


def setup_observability(app: FastAPI, service_name: str) -> None:
    os.environ["OTEL_SERVICE_NAME"] = service_name
    configure_logging()

    resource = Resource.create(
        {
            "service.name": service_name,
            "deployment.environment": os.getenv("ENVIRONMENT", "development"),
        }
    )
    provider = TracerProvider(resource=resource)
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if endpoint:
        exporter = OTLPSpanExporter(endpoint=f"{endpoint.rstrip('/')}/v1/traces")
        provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    FastAPIInstrumentor.instrument_app(
        app,
        tracer_provider=provider,
        excluded_urls="health,ready,metrics",
    )
    HTTPXClientInstrumentor().instrument(tracer_provider=provider)

    request_counter = Counter(
        "lms_http_requests_total",
        "Total number of HTTP requests",
        ("service", "method", "route", "status"),
    )
    request_duration = Histogram(
        "lms_http_request_duration_seconds",
        "HTTP request duration in seconds",
        ("service", "method", "route"),
    )
    app.add_middleware(
        MetricsMiddleware,
        service_name=service_name,
        request_counter=request_counter,
        request_duration=request_duration,
    )

    async def metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    app.add_api_route("/metrics", metrics, include_in_schema=False)


"""Prometheus + OTel + structlog wiring.

Single source of truth for the metric/span/log namespace.
"""
from __future__ import annotations

import logging
import os
import sys
import time

import requests
import structlog
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import Counter, Gauge, Histogram

# ── Prometheus metrics ────────────────────────────────────────
INFERENCE_REQUESTS = Counter(
    "inference_requests_total",
    "Total inference requests",
    ["model", "status"],
)
INFERENCE_LATENCY = Histogram(
    "inference_latency_seconds",
    "Inference end-to-end latency",
    ["model"],
    buckets=(0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0),
)
INFERENCE_ACTIVE = Gauge(
    "inference_active_gauge",
    "In-flight inference requests",
)
INFERENCE_TOKENS = Counter(
    "inference_tokens_total",
    "Tokens processed (input/output)",
    ["model", "direction"],
)
INFERENCE_QUALITY = Gauge(
    "inference_quality_score",
    "Latest eval-as-metric quality score [0,1]",
    ["model"],
)
GPU_UTIL = Gauge(
    "gpu_utilization_percent",
    "Simulated GPU utilization [0,100]",
)

tracer = trace.get_tracer(__name__)


def setup_otel() -> None:
    """Configure OTLP trace export + FastAPI auto-instrumentation."""
    resource = Resource.create(
        {
            "service.name": os.getenv("OTEL_SERVICE_NAME", "inference-api"),
            "service.namespace": "aicb",
            "deployment.environment": os.getenv(
                "DEPLOY_ENV",
                "lab",
            ),
        }
    )
    provider = TracerProvider(resource=resource)
    # gRPC exporter expects host:port (no http:// scheme)
    raw_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317")
    # Strip http:// or https:// if present (gRPC transport adds its own)
    grpc_endpoint = raw_endpoint.replace("http://", "").replace("https://", "")
    provider.add_span_processor(
        BatchSpanProcessor(
            OTLPSpanExporter(endpoint=grpc_endpoint, insecure=True)
        )
    )
    trace.set_tracer_provider(provider)
    # Auto-instrument FastAPI handlers (creates server spans for every route)
    from fastapi import FastAPI  # local import: only needed at setup

    FastAPIInstrumentor().instrument()
    _configure_logging()


def _configure_logging() -> None:
    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=os.getenv("LOG_LEVEL", "INFO"),
    )
    loki_endpoint = os.getenv("LOKI_ENDPOINT", "http://loki:3100/loki/api/v1/push")

    _loki_buffer: list[dict] = []
    _loki_lock = __import__("threading").Lock()

    def _loki_processor(logger, method_name, event_dict):
        ts_ns = str(int(time.time() * 1e9))
        msg = event_dict.pop("event", "")
        level = event_dict.pop("level", "info")
        with _loki_lock:
            _loki_buffer.append(
                {
                    "stream": {
                        "app": "day23-app",
                        "service": "inference-api",
                        "level": level,
                    },
                    "values": [[ts_ns, msg]],
                }
            )
        if len(_loki_buffer) >= 50 or method_name in ("error", "critical"):
            try:
                payload = {"streams": _loki_buffer[:50]}
                requests.post(loki_endpoint, json=payload, timeout=2)
                with _loki_lock:
                    _loki_buffer[:] = _loki_buffer[50:]
            except Exception:
                pass
        return event_dict

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            _loki_processor,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


def bind_log(name: str) -> structlog.BoundLogger:
    return structlog.get_logger(name)

"""FastAPI mock LLM inference service.

Emits Prometheus metrics, OTLP traces, and structured JSON logs.
"""
from __future__ import annotations

import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel

from instrumentation import (
    GPU_UTIL,
    INFERENCE_ACTIVE,
    INFERENCE_LATENCY,
    INFERENCE_QUALITY,
    INFERENCE_REQUESTS,
    INFERENCE_TOKENS,
    bind_log,
    setup_otel,
    tracer,
)
from inference import simulate_inference, simulate_gpu_load
import os
import pyroscope
from langfuse import Langfuse

pyroscope.configure(
  application_name="day23-app",
  server_address="http://day23-pyroscope:4040",
)

langfuse = Langfuse(
  public_key=os.environ.get("LANGFUSE_PUBLIC_KEY"),
  secret_key=os.environ.get("LANGFUSE_SECRET_KEY"),
  host=os.environ.get("LANGFUSE_HOST")
)


@asynccontextmanager
async def lifespan(_: FastAPI):
    setup_otel()
    yield


app = FastAPI(title="day23-inference-api", lifespan=lifespan)
log = bind_log("main")


class PredictRequest(BaseModel):
    prompt: str
    model: str = "llama3-mock"
    fail: bool = False  # for alert demos


class PredictResponse(BaseModel):
    text: str
    model: str
    input_tokens: int
    output_tokens: int
    trace_id: str
    quality_score: float


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/metrics")
def metrics() -> Response:
    GPU_UTIL.set(simulate_gpu_load())
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest) -> PredictResponse:
    INFERENCE_ACTIVE.inc()
    start = time.perf_counter()

    with tracer.start_as_current_span("predict") as span:
        span.set_attribute("gen_ai.request.model", req.model)

        try:
            if req.fail:
                INFERENCE_REQUESTS.labels(model=req.model, status="error").inc()
                log.error("forced failure", model=req.model)
                raise HTTPException(status_code=503, detail="forced failure (alert demo)")

            with tracer.start_as_current_span("embed-text") as embed_span:
                embed_span.set_attribute("text.length", len(req.prompt))
                time.sleep(0.005)

            with tracer.start_as_current_span("vector-search") as search_span:
                search_span.set_attribute("k", 5)
                time.sleep(0.010)

            with tracer.start_as_current_span("generate-tokens") as gen_span:
                text, in_toks, out_toks, quality = simulate_inference(req.prompt, req.model)
                gen_span.set_attribute("gen_ai.usage.input_tokens", in_toks)
                gen_span.set_attribute("gen_ai.usage.output_tokens", out_toks)
                gen_span.set_attribute("gen_ai.response.finish_reason", "stop")

                # LANGFUSE TRACE (BONUS B2)
                lf_trace = langfuse.trace(name="predict_request", session_id="test_session")
                lf_trace.generation(
                    name="simulate_inference",
                    model=req.model,
                    input=req.prompt,
                    output=text,
                    usage={"input": in_toks, "output": out_toks},
                    metadata={"quality_score": quality}
                )
                langfuse.flush()

            INFERENCE_REQUESTS.labels(model=req.model, status="ok").inc()
            INFERENCE_TOKENS.labels(model=req.model, direction="input").inc(in_toks)
            INFERENCE_TOKENS.labels(model=req.model, direction="output").inc(out_toks)
            INFERENCE_QUALITY.labels(model=req.model).set(quality)

            elapsed = time.perf_counter() - start
            INFERENCE_LATENCY.labels(model=req.model).observe(elapsed)

            trace_id = format(span.get_span_context().trace_id, "032x")
            log.info(
                "prediction served",
                model=req.model,
                input_tokens=in_toks,
                output_tokens=out_toks,
                quality=quality,
                duration_seconds=round(elapsed, 4),
                trace_id=trace_id,
            )
            return PredictResponse(
                text=text,
                model=req.model,
                input_tokens=in_toks,
                output_tokens=out_toks,
                trace_id=trace_id,
                quality_score=quality,
            )
        finally:
            INFERENCE_ACTIVE.dec()


"""
agents/orchestrator/main.py

Receives task requests, decomposes them via Azure OpenAI, publishes
sub-tasks to Service Bus topics, and aggregates results by correlation ID.
"""

import asyncio
import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from azure.identity.aio import DefaultAzureCredential
from azure.servicebus.aio import ServiceBusClient
from azure.servicebus import ServiceBusMessage
from fastapi import FastAPI, HTTPException
from openai import AsyncAzureOpenAI
from pydantic import BaseModel

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
log = logging.getLogger("orchestrator")

# ---------------------------------------------------------------------------
# Config from environment (injected via Key Vault CSI + secretKeyRef)
# ---------------------------------------------------------------------------

OPENAI_ENDPOINT = os.environ["AZURE_OPENAI_ENDPOINT"]
OPENAI_DEPLOYMENT = os.environ["AZURE_OPENAI_DEPLOYMENT"]
SERVICEBUS_NAMESPACE = os.environ["SERVICEBUS_NAMESPACE"]

TASK_TOPICS = {
    "research":  "research-tasks",
    "analysis":  "analysis-tasks",
    "writer":    "writer-tasks",
}
RESULTS_TOPIC = "agent-results"
RESULTS_SUBSCRIPTION = "sub-orchestrator"

# In-memory job store — swap for Redis/CosmosDB in production
job_store: dict[str, dict] = {}

credential: DefaultAzureCredential | None = None
sb_client: ServiceBusClient | None = None
openai_client: AsyncAzureOpenAI | None = None


# ---------------------------------------------------------------------------
# Lifespan — initialise and cleanly close Azure clients
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    global credential, sb_client, openai_client

    credential = DefaultAzureCredential()
    sb_client = ServiceBusClient(
        fully_qualified_namespace=SERVICEBUS_NAMESPACE,
        credential=credential,
    )
    openai_client = AsyncAzureOpenAI(
        azure_endpoint=OPENAI_ENDPOINT,
        azure_ad_token_provider=_token_provider,
        api_version="2024-10-21",
    )

    # Start background result listener
    asyncio.create_task(_listen_for_results())
    log.info("Orchestrator started")

    yield

    await sb_client.close()
    await credential.close()


async def _token_provider() -> str:
    token = await credential.get_token(
        "https://cognitiveservices.azure.com/.default"
    )
    return token.token


app = FastAPI(title="orchestrator", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class TaskRequest(BaseModel):
    prompt: str
    context: dict = {}


class TaskResponse(BaseModel):
    job_id: str
    status: str
    message: str


class JobStatus(BaseModel):
    job_id: str
    status: str
    created_at: str
    results: list[dict] = []


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/health/ready")
async def ready():
    if not sb_client or not openai_client:
        raise HTTPException(status_code=503, detail="Not ready")
    return {"status": "ready"}


@app.post("/tasks", response_model=TaskResponse)
async def submit_task(request: TaskRequest):
    """
    Decompose the incoming prompt into sub-tasks and fan out to worker agents.
    """
    job_id = str(uuid.uuid4())
    correlation_id = job_id

    log.info(f"Job {job_id}: decomposing prompt")

    # Ask GPT-4o to decompose the task into typed sub-tasks
    decomposition = await _decompose_task(request.prompt, request.context)

    job_store[job_id] = {
        "job_id": job_id,
        "status": "running",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "subtasks": decomposition,
        "results": [],
        "expected_results": len(decomposition),
    }

    # Publish each sub-task to the appropriate agent topic
    for subtask in decomposition:
        agent_type = subtask["agent"]
        topic = TASK_TOPICS.get(agent_type)
        if not topic:
            log.warning(f"Unknown agent type: {agent_type}, skipping")
            continue

        message_body = json.dumps({
            "job_id": job_id,
            "correlation_id": correlation_id,
            "agent": agent_type,
            "task": subtask["task"],
            "context": request.context,
        })

        async with sb_client.get_topic_sender(topic_name=topic) as sender:
            msg = ServiceBusMessage(
                body=message_body,
                correlation_id=correlation_id,
                message_id=str(uuid.uuid4()),
                content_type="application/json",
            )
            await sender.send_messages(msg)
            log.info(f"Job {job_id}: published sub-task to {topic}")

    return TaskResponse(
        job_id=job_id,
        status="running",
        message=f"Job accepted. {len(decomposition)} sub-tasks dispatched.",
    )


@app.get("/tasks/{job_id}", response_model=JobStatus)
async def get_job_status(job_id: str):
    job = job_store.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return JobStatus(**job)


# ---------------------------------------------------------------------------
# Task decomposition via Azure OpenAI
# ---------------------------------------------------------------------------

DECOMPOSE_SYSTEM_PROMPT = """
You are a task decomposition engine. Given a user prompt, break it into
sub-tasks for three specialist agents: research, analysis, and writer.

Respond with a JSON array only. Each item must have:
  - "agent": one of "research", "analysis", "writer"
  - "task": a clear, self-contained instruction for that agent

Example:
[
  {"agent": "research", "task": "Find recent data on X"},
  {"agent": "analysis", "task": "Analyse the findings and identify patterns"},
  {"agent": "writer",   "task": "Write a concise executive summary"}
]
"""


async def _decompose_task(prompt: str, context: dict) -> list[dict]:
    response = await openai_client.chat.completions.create(
        model=OPENAI_DEPLOYMENT,
        messages=[
            {"role": "system", "content": DECOMPOSE_SYSTEM_PROMPT},
            {"role": "user", "content": f"Prompt: {prompt}\nContext: {json.dumps(context)}"},
        ],
        temperature=0.2,
        response_format={"type": "json_object"},
    )

    raw = response.choices[0].message.content
    parsed = json.loads(raw)

    # Handle both {"tasks": [...]} and [...] shapes
    if isinstance(parsed, list):
        return parsed
    return parsed.get("tasks", parsed.get("subtasks", []))


# ---------------------------------------------------------------------------
# Background result listener
# ---------------------------------------------------------------------------

async def _listen_for_results():
    """
    Continuously reads from the agent-results topic subscription.
    Matches results back to jobs by correlation_id and marks jobs complete.
    """
    log.info("Result listener started")
    while True:
        try:
            async with sb_client.get_subscription_receiver(
                topic_name=RESULTS_TOPIC,
                subscription_name=RESULTS_SUBSCRIPTION,
                max_wait_time=5,
            ) as receiver:
                async for msg in receiver:
                    try:
                        body = json.loads(str(msg))
                        job_id = body.get("job_id") or body.get("correlation_id")

                        if job_id and job_id in job_store:
                            job_store[job_id]["results"].append(body)
                            received = len(job_store[job_id]["results"])
                            expected = job_store[job_id]["expected_results"]

                            if received >= expected:
                                job_store[job_id]["status"] = "complete"
                                log.info(f"Job {job_id}: complete")
                            else:
                                log.info(f"Job {job_id}: {received}/{expected} results received")

                        await receiver.complete_message(msg)

                    except Exception as e:
                        log.error(f"Error processing result message: {e}")
                        await receiver.dead_letter_message(msg, reason=str(e))

        except Exception as e:
            log.error(f"Result listener error: {e}. Retrying in 5s...")
            await asyncio.sleep(5)

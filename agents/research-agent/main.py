"""
agents/research-agent/main.py

Listens on the research-tasks Service Bus topic.
For each task: calls Azure OpenAI to perform retrieval-augmented research,
then publishes the result to agent-results.
"""

import asyncio
import json
import logging
import os

from azure.identity.aio import DefaultAzureCredential
from azure.servicebus.aio import ServiceBusClient
from azure.servicebus import ServiceBusMessage
from fastapi import FastAPI, HTTPException
from openai import AsyncAzureOpenAI
from contextlib import asynccontextmanager

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
log = logging.getLogger("research-agent")

OPENAI_ENDPOINT = os.environ["AZURE_OPENAI_ENDPOINT"]
OPENAI_DEPLOYMENT = os.environ["AZURE_OPENAI_DEPLOYMENT"]
SERVICEBUS_NAMESPACE = os.environ["SERVICEBUS_NAMESPACE"]
TOPIC_NAME = os.environ.get("SERVICEBUS_TOPIC", "research-tasks")
SUBSCRIPTION_NAME = os.environ.get("SERVICEBUS_SUBSCRIPTION", "sub-research-agent")
RESULTS_TOPIC = "agent-results"

credential: DefaultAzureCredential | None = None
sb_client: ServiceBusClient | None = None
openai_client: AsyncAzureOpenAI | None = None


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

    asyncio.create_task(_process_tasks())
    log.info("Research agent started")

    yield

    await sb_client.close()
    await credential.close()


async def _token_provider() -> str:
    token = await credential.get_token(
        "https://cognitiveservices.azure.com/.default"
    )
    return token.token


app = FastAPI(title="research-agent", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/health/ready")
async def ready():
    if not sb_client or not openai_client:
        raise HTTPException(status_code=503, detail="Not ready")
    return {"status": "ready"}


RESEARCH_SYSTEM_PROMPT = """
You are a specialist research agent. Given a research task, produce a
structured research summary with:
  - key_findings: list of the most relevant facts or data points
  - sources_consulted: what kinds of sources would contain this information
  - confidence: "high", "medium", or "low"
  - summary: a 2-3 sentence synthesis

Respond with JSON only.
"""


async def _process_tasks():
    log.info("Task processor started")
    while True:
        try:
            async with sb_client.get_subscription_receiver(
                topic_name=TOPIC_NAME,
                subscription_name=SUBSCRIPTION_NAME,
                max_wait_time=5,
            ) as receiver:
                async for msg in receiver:
                    try:
                        body = json.loads(str(msg))
                        job_id = body["job_id"]
                        task = body["task"]
                        log.info(f"Job {job_id}: processing research task")

                        result = await _research(task, body.get("context", {}))

                        await _publish_result(job_id, body.get("correlation_id", job_id), result)
                        await receiver.complete_message(msg)
                        log.info(f"Job {job_id}: research complete")

                    except Exception as e:
                        log.error(f"Error processing message: {e}")
                        await receiver.dead_letter_message(msg, reason=str(e))

        except Exception as e:
            log.error(f"Receiver error: {e}. Retrying in 5s...")
            await asyncio.sleep(5)


async def _research(task: str, context: dict) -> dict:
    response = await openai_client.chat.completions.create(
        model=OPENAI_DEPLOYMENT,
        messages=[
            {"role": "system", "content": RESEARCH_SYSTEM_PROMPT},
            {"role": "user", "content": f"Task: {task}\nContext: {json.dumps(context)}"},
        ],
        temperature=0.3,
        response_format={"type": "json_object"},
    )
    return json.loads(response.choices[0].message.content)


async def _publish_result(job_id: str, correlation_id: str, result: dict):
    payload = json.dumps({
        "job_id": job_id,
        "correlation_id": correlation_id,
        "agent": "research-agent",
        "result": result,
    })
    async with sb_client.get_topic_sender(topic_name=RESULTS_TOPIC) as sender:
        await sender.send_messages(
            ServiceBusMessage(
                body=payload,
                correlation_id=correlation_id,
                content_type="application/json",
            )
        )

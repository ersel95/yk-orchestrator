from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import get_settings
from app.core.db import init_db
from app.core.logging import get_logger, setup_logging
from app.routers import (
    chat,
    health,
    jira,
    llm as llm_router,
    projects,
    pull_requests,
    settings as settings_router,
    standup,
    stream,
    testflight,
    transcript,
    wizard,
)

setup_logging()
log = get_logger(__name__)
settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("[bold green]Orchestrator başlıyor[/]")
    init_db()
    yield
    log.info("Orchestrator kapanıyor")


app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[settings.dashboard_allow_origin, "http://127.0.0.1:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(jira.router)
app.include_router(pull_requests.router)
app.include_router(standup.router)
app.include_router(transcript.router)
app.include_router(chat.router)
app.include_router(testflight.router)
app.include_router(settings_router.router)
app.include_router(stream.router)
app.include_router(llm_router.router)
app.include_router(projects.router)
app.include_router(wizard.router)


def run() -> None:
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=settings.api_host,
        port=settings.api_port,
        reload=settings.app_env == "local",
    )


if __name__ == "__main__":
    run()

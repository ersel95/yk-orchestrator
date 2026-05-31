from fastapi import APIRouter

from app.integrations.bitbucket_client import get_bitbucket
from app.integrations.jira_client import get_jira
from app.integrations.llm import get_llm

router = APIRouter(prefix="/health", tags=["health"])


@router.get("")
async def health() -> dict:
    llm_ok = await get_llm().health()
    jira_ok = await get_jira().health()
    bb_ok = await get_bitbucket().health()
    return {
        "ok": True,
        "llm": llm_ok,
        "jira": jira_ok,
        "bitbucket": bb_ok,
    }

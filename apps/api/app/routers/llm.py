from fastapi import APIRouter

from app.integrations.llm import get_llm

router = APIRouter(prefix="/api/llm", tags=["llm"])


@router.post("/sleep")
async def sleep_llm() -> dict:
    """Genel modeli LM Studio'dan boşalt — RAM rahatlatır."""
    return await get_llm().unload()


@router.post("/sleep-all")
async def sleep_all() -> dict:
    """Tüm yüklü modelleri (general + code + embed) boşalt."""
    llm = get_llm()
    results = []
    for kind in ("general", "code", "embed"):
        results.append(await llm.unload(llm.model_for(kind)))
    return {"results": results}

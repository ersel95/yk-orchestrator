from fastapi import APIRouter

from app.core.config import get_settings

router = APIRouter(prefix="/api/settings", tags=["settings"])


@router.get("")
async def get_app_settings() -> dict:
    s = get_settings()
    masked_token = "***" if s.jira_api_token else ""
    masked_pw = "***" if s.bitbucket_app_password else ""
    return {
        "app_name": s.app_name,
        "timezone": s.timezone,
        "llm": {
            "base_url": s.llm_base_url,
            "general": s.llm_model_general,
            "code": s.llm_model_code,
            "embed": s.llm_model_embed,
        },
        "jira": {
            "base_url": s.jira_base_url,
            "email": s.jira_email,
            "configured": bool(masked_token),
            "projects": s.jira_project_list,
        },
        "bitbucket": {
            "base_url": s.bitbucket_base_url,
            "username": s.bitbucket_username,
            "workspace": s.bitbucket_workspace,
            "default_repo": s.bitbucket_default_repo,
            "configured": bool(masked_pw),
        },
        "git": {
            "local_repo_path": s.local_repo_path,
            "default_branch": s.git_default_branch,
        },
        "fastlane": {
            "lane": s.fastlane_lane,
            "project_dir": s.fastlane_project_dir,
        },
        "scheduler": {
            "daily_fetch_hour": s.daily_fetch_hour,
            "daily_fetch_minute": s.daily_fetch_minute,
        },
    }

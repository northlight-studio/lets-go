from typing import Literal

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://letsgo:letsgo_dev@localhost:5433/letsgo"
    # How close you have to be to check in, in meters.
    check_in_radius_m: float = 200
    # Check-in opens this many minutes before a gathering starts.
    check_in_early_min: int = 30
    # The default "near you" radius for the map.
    nearby_radius_m: float = 2500
    # Run the nightly sweep from the API process (off in tests and one-off scripts).
    catalog_scheduler: bool = True
    # The one place a model is named, as in Pulse: every Responses API call uses `ai_model`. GPT-6
    # family; reasoning models reject `temperature`, so no call passes one. The scout runs only when
    # there's a key (OPENAI_API_KEY, the same one Pulse uses).
    openai_api_key: str = ""
    ai_model: str = "gpt-6-luna"
    scout_reasoning_effort: Literal["low", "medium", "high"] = "medium"
    # A day's scout spend per city at list prices, and runs one person can start in an hour.
    scout_daily_budget_usd: float = 40
    scout_runs_per_hour: int = 5

    @field_validator("database_url")
    @classmethod
    def _async_driver(cls, url: str) -> str:
        """Railway hands out postgresql:// (or postgres://); SQLAlchemy async needs the asyncpg driver."""
        for prefix in ("postgres://", "postgresql://"):
            if url.startswith(prefix):
                return "postgresql+asyncpg://" + url[len(prefix) :]
        return url


settings = Settings()

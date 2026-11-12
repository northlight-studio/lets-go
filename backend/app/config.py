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
    # The nightly reader (app.catalog.sources): the model's effort on a changed page with no structure,
    # and at most this many such pages a night. Its spend counts against scout_daily_budget_usd.
    reader_reasoning_effort: Literal["low", "medium", "high"] = "low"
    reader_model_pages: int = 150
    # The source finder: searches a night (0 = a seventh of the neighborhood × kind grid).
    finder_runs_per_night: int = 0
    finder_enabled: bool = True
    # `X-Admin-Token` for /v1/admin/*. Empty turns those routes off.
    admin_token: str = ""

    # Where a poster's short link points: this API's own public address (or a short domain aimed at it).
    public_base_url: str = "https://api-production-658b9.up.railway.app"
    # Where the poster page sends people to get the app (TestFlight public link or App Store page).
    # Empty: the page says the app is in beta on iPhone and to ask the host.
    app_download_url: str = ""
    # Mixed into IP hashes so the stored hashes can't be reversed by hashing every address.
    web_ip_salt: str = "letsgo-dev-salt"
    # Proxies in front of the API that append to X-Forwarded-For (Railway's edge: one).
    trusted_proxy_hops: int = 1
    # Joins from the web: at most this share of a capped gathering's spots, this many for an open one,
    # this many per network per gathering, and this many per network per hour across all posters.
    web_share_of_spots: float = 0.5
    web_open_max: int = 25
    web_per_ip_per_gathering: int = 3
    web_per_ip_per_hour: int = 6

    # Payments (Stripe). With no secret and publishable key, every order is "pay at pickup".
    # Card and Apple Pay through PaymentSheet on the phone, PaymentIntents here, and Connect Express
    # accounts for sellers' payouts (destination charges: the app keeps the service fee).
    stripe_secret_key: str = ""
    stripe_publishable_key: str = ""
    stripe_webhook_secret: str = ""
    # The Apple Pay merchant id (merchant.com.…). Empty: PaymentSheet offers cards only.
    apple_pay_merchant_id: str = ""
    stripe_country: str = "US"

    @property
    def payments_enabled(self) -> bool:
        return bool(self.stripe_secret_key and self.stripe_publishable_key)

    @field_validator("database_url")
    @classmethod
    def _async_driver(cls, url: str) -> str:
        """Railway hands out postgresql:// (or postgres://); SQLAlchemy async needs the asyncpg driver."""
        for prefix in ("postgres://", "postgresql://"):
            if url.startswith(prefix):
                return "postgresql+asyncpg://" + url[len(prefix) :]
        return url


settings = Settings()

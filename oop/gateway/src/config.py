from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    orchestrator_url: str = "http://10.53.3.40:8090"
    open5gs_nef_url: str = "http://10.53.3.20:7777"
    open5gs_pcf_url: str = "http://10.53.3.20:7000"
    log_level: str = "INFO"

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"

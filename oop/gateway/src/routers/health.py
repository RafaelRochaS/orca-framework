from fastapi import APIRouter
from fastapi.responses import JSONResponse

router = APIRouter(tags=["Health"])


@router.get("/healthz", include_in_schema=False)
async def health():
    return JSONResponse({"status": "ok", "service": "oop-gateway"})

"""Read development demo credentials without a checked-in fallback password."""

import json
import os
from pathlib import Path
from typing import Literal

_LOCAL_CONFIG = Path(__file__).resolve().parents[2] / "deployment" / "secrets.json"
_OVERRIDES = {
    "staff": ("MALL_DEMO_ADMIN_PASSWORD",),
    "member": ("MALL_DEMO_MEMBER_PASSWORD", "MALL_DEMO_PASSWORD"),
}


def demo_password(role: Literal["staff", "member"]) -> str:
    keys = _OVERRIDES[role]
    for key in keys:
        value = os.environ.get(key)
        if value:
            return value
    try:
        config = json.loads(_LOCAL_CONFIG.read_text(encoding="utf-8-sig"))
        value = config.get("demoPassword") if isinstance(config, dict) else None
    except FileNotFoundError:
        value = None
    except (OSError, UnicodeError, ValueError):
        raise RuntimeError("Unable to read the private development credential configuration.") from None
    if not isinstance(value, str) or not value:
        raise RuntimeError(f"Set {keys[0]} or generate the ignored local deployment configuration.")
    return value

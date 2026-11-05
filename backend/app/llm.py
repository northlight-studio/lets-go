"""Every model call goes through here, the same way Pulse's `app/services/llm.py` works: a call site
builds an OpenAI Responses API request and hands it to `create(client, **kwargs)` instead of calling
`client.responses.create` itself. Today that's a straight pass-through to OpenAI; a provider switch
(Pulse's `AI_PROVIDER`) would go here and nowhere else.

Every call names its prompt-cache key, `letsgo:<surface>:v<n>`, and puts its stable context first so
the prefix actually caches. Bump the `v` when that prefix changes shape.
"""

import re
from typing import Any

_CACHE_KEY = re.compile(r"^letsgo:[a-z_]+:v\d+$")


async def create(client: Any, **kwargs: Any) -> Any:
    """`client.responses.create(**kwargs)`, after checking the call follows the house rules."""
    key = kwargs.get("prompt_cache_key")
    if not isinstance(key, str) or not _CACHE_KEY.match(key):
        raise ValueError("every model call passes prompt_cache_key='letsgo:<surface>:v<n>'")
    if "temperature" in kwargs:
        raise ValueError("reasoning models reject temperature; leave it out")
    return await client.responses.create(**kwargs)

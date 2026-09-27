from __future__ import annotations

import os
import random
import string
from locust import HttpUser, between, task

# Configuration from environment variables
CONCURRENCY = int(os.environ.get("LOCUST_CONCURRENCY", "4"))
SPAWN_RATE = int(os.environ.get("LOCUST_SPAWN_RATE", "2"))
DURATION = int(os.environ.get("LOCUST_DURATION", "60"))
PROMPT_LENGTH = int(os.environ.get("LOCUST_PROMPT_LENGTH", "16"))
MAX_TOKENS = int(os.environ.get("LOCUST_MAX_TOKENS", "32"))
PROFILE = os.environ.get("LOCUST_PROFILE", "baseline")

# Workload profile configurations
PROFILES = {
    "baseline": {
        "prompt_length": 16,
        "max_tokens": 32,
        "description": "Short input, short output - baseline performance"
    },
    "prefill_stress": {
        "prompt_length": 8192,
        "max_tokens": 32,
        "description": "Long input, short output - stress prefill phase"
    },
    "decode_stress": {
        "prompt_length": 16,
        "max_tokens": 512,
        "description": "Short input, long output - stress decode phase"
    },
    "cache_hit": {
        "prompt_length": 256,
        "max_tokens": 64,
        "description": "Repeated prefix prompts - test cache reuse"
    },
    "cache_miss": {
        "prompt_length": 64,
        "max_tokens": 32,
        "description": "Unique random prompts - test cache misses"
    }
}

# Get current profile configuration
profile_config = PROFILES.get(PROFILE, PROFILES["baseline"])
EFFECTIVE_PROMPT_LENGTH = PROMPT_LENGTH if PROMPT_LENGTH != 16 else profile_config["prompt_length"]
EFFECTIVE_MAX_TOKENS = MAX_TOKENS if MAX_TOKENS != 32 else profile_config["max_tokens"]

# Standard prompts for baseline
BASELINE_PROMPTS = (
    "Write one sentence about a GPU.",
    "Name three things KV cache is used for.",
    "Explain prefix caching in one sentence.",
    "What is a decode replica for?",
    "Say hello from class 9b load.",
)

# Long prompt template for prefill stress
LONG_PROMPT_TEMPLATE = "Please analyze the following concept in detail: {content}. " \
                       "Consider its implications, applications, and limitations. " \
                       "Provide a comprehensive explanation covering technical aspects, " \
                       "practical considerations, and potential future developments. " \
                       "Your response should be thorough yet concise, focusing on key insights " \
                       "and actionable information. Please ensure your analysis is well-structured " \
                       "and addresses multiple dimensions of the topic."

# Cache-friendly prompts (same prefix)
CACHE_PREFIX = "In the context of modern LLM inference systems, "
CACHE_PROMPTS = (
    CACHE_PREFIX + "explain the role of prefix caching.",
    CACHE_PREFIX + "describe the benefits of KV cache sharing.",
    CACHE_PREFIX + "analyze the trade-offs in token allocation.",
    CACHE_PREFIX + "discuss the importance of queue management.",
    CACHE_PREFIX + "evaluate the impact of admission control.",
)

# Tiny PNG for vision tests
TINY_PNG = (
    "data:image/png;base64,"
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)

def generate_long_prompt(target_length: int) -> str:
    """Generate a long prompt of approximately target_length characters"""
    # Repeat the template to reach target length
    base = LONG_PROMPT_TEMPLATE
    content = "GPU acceleration, memory management, distributed computing, " \
              "neural network optimization, cache coherence, load balancing, " \
              "resource allocation, throughput optimization, latency reduction."
    
    result = base.format(content=content)
    while len(result) < target_length:
        result += " " + content
    
    return result[:target_length]

def generate_unique_prompt(length: int) -> str:
    """Generate a unique random prompt"""
    chars = string.ascii_letters + string.digits + " "
    return ''.join(random.choice(chars) for _ in range(length))

def get_prompt_for_profile() -> str:
    """Get appropriate prompt based on current profile"""
    if PROFILE == "baseline":
        return random.choice(BASELINE_PROMPTS)
    elif PROFILE == "prefill_stress":
        return generate_long_prompt(EFFECTIVE_PROMPT_LENGTH)
    elif PROFILE == "decode_stress":
        return random.choice(BASELINE_PROMPTS)
    elif PROFILE == "cache_hit":
        return random.choice(CACHE_PROMPTS)
    elif PROFILE == "cache_miss":
        return generate_unique_prompt(EFFECTIVE_PROMPT_LENGTH)
    else:
        return random.choice(BASELINE_PROMPTS)


class EnhancedChatUser(HttpUser):
    """Enhanced Locust user with configurable workload profiles"""
    
    wait_time = between(0.4, 1.2)
    host = os.environ.get("LOCUST_HOST", "http://127.0.0.1:8080")

    def on_start(self) -> None:
        self.tenant = f"locust-{PROFILE}-{id(self) % 10_000}"
        print(f"User started: profile={PROFILE}, tenant={self.tenant}, "
              f"prompt_length={EFFECTIVE_PROMPT_LENGTH}, max_tokens={EFFECTIVE_MAX_TOKENS}")

    def _chat(self, payload: dict) -> None:
        """Send chat completion request"""
        payload["tenant"] = getattr(self, "tenant", "locust")
        
        with self.client.post(
            "/v1/chat/completions",
            json=payload,
            name=f"/v1/chat/completions [{PROFILE}]",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                resp.success()
            elif resp.status_code == 429:
                # Rate limiting is expected behavior
                resp.success()
            elif resp.status_code == 503:
                # Service overload is expected under stress
                resp.success()
            else:
                resp.failure(f"{resp.status_code} {resp.text[:160]}")

    @task(8)
    def text_task(self) -> None:
        """Text generation task"""
        self._chat(
            {
                "model": "text",
                "messages": [{"role": "user", "content": get_prompt_for_profile()}],
                "max_tokens": EFFECTIVE_MAX_TOKENS,
            }
        )

    @task(1)
    def vision_task(self) -> None:
        """Vision task - mostly for baseline, limited in stress tests"""
        if PROFILE in ["prefill_stress", "decode_stress"]:
            # Skip vision in stress tests to focus on text workload
            return
            
        self._chat(
            {
                "model": "vision",
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": "What color is this?"},
                            {"type": "image_url", "image_url": {"url": TINY_PNG}},
                        ],
                    }
                ],
                "max_tokens": EFFECTIVE_MAX_TOKENS,
            }
        )

    @task(1)
    def cache_hop_task(self) -> None:
        """Task that triggers KV cache hop"""
        if PROFILE != "cache_hit":
            # Only run in cache_hit profile
            return
            
        self._chat(
            {
                "model": "text",
                "messages": [{"role": "user", "content": get_prompt_for_profile()}],
                "max_tokens": EFFECTIVE_MAX_TOKENS,
                "kv_hop": True,  # Force KV hop
            }
        )


# Legacy compatibility - keep original class name
class ChatUser(EnhancedChatUser):
    """Legacy class name for backward compatibility"""
    pass


if __name__ == "__main__":
    # Print configuration when run directly
    print(f"Locust Enhanced Configuration:")
    print(f"  Profile: {PROFILE}")
    print(f"  Description: {profile_config['description']}")
    print(f"  Concurrency: {CONCURRENCY}")
    print(f"  Spawn Rate: {SPAWN_RATE}")
    print(f"  Duration: {DURATION}s")
    print(f"  Prompt Length: {EFFECTIVE_PROMPT_LENGTH}")
    print(f"  Max Tokens: {EFFECTIVE_MAX_TOKENS}")
    print(f"  Host: {EnhancedChatUser.host}")

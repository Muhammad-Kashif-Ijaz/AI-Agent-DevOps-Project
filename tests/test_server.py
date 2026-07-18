from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

import httpx
from fastapi.testclient import TestClient


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class AssistantServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory()
        root = Path(cls.temporary.name)
        os.environ["APP_ENV"] = "test"
        os.environ["AGENT_TEST_MODE"] = "1"
        os.environ["AGENT_DATA_DIR"] = str(root / "data")
        os.environ["AGENT_ENV_FILE"] = str(root / ".env")
        os.environ["OLLAMA_BASE_URL"] = "http://127.0.0.1:11434"
        os.environ["OLLAMA_MODEL"] = "qwen3:8b"
        os.environ["OLLAMA_THINK"] = "true"

        spec = importlib.util.spec_from_file_location(
            "enterprise_agent_server_tests", PROJECT_ROOT / "server.py"
        )
        assert spec and spec.loader
        cls.module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.module
        spec.loader.exec_module(cls.module)
        cls.client_context = TestClient(cls.module.app)
        cls.client = cls.client_context.__enter__()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.client_context.__exit__(None, None, None)
        cls.temporary.cleanup()

    def test_status_is_neutral_and_security_headers_are_set(self) -> None:
        response = self.client.get("/api/status")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {"configured": True, "ready": True, "status": "ready"},
        )
        self.assertEqual(response.headers["x-content-type-options"], "nosniff")
        self.assertEqual(response.headers["x-frame-options"], "DENY")
        self.assertIn(
            "microphone=(self)", response.headers["permissions-policy"]
        )
        self.assertNotIn("microphone=()", response.headers["permissions-policy"])
        self.assertNotIn("model", response.text.lower())
        self.assertNotIn("provider", response.text.lower())

    def test_usage_limit_settings_are_bounded(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"AGENT_USAGE_LIMIT_PER_HOUR": "0", "AGENT_TRUST_PROXY": "1"},
        ):
            lower = self.module.Settings()
        with mock.patch.dict(
            os.environ,
            {"AGENT_USAGE_LIMIT_PER_HOUR": "999999", "AGENT_TRUST_PROXY": "0"},
        ):
            upper = self.module.Settings()
        with mock.patch.dict(
            os.environ,
            {"AGENT_USAGE_LIMIT_PER_HOUR": "invalid", "AGENT_TRUST_PROXY": "true"},
        ):
            fallback = self.module.Settings()

        self.assertEqual(lower.usage_limit_per_hour, 1)
        self.assertTrue(lower.trust_proxy)
        self.assertEqual(upper.usage_limit_per_hour, 1000)
        self.assertFalse(upper.trust_proxy)
        self.assertEqual(fallback.usage_limit_per_hour, 60)
        self.assertFalse(fallback.trust_proxy)

    def test_ollama_think_boolean_parsing(self) -> None:
        for value in ("1", "true", "TRUE", "yes", "on"):
            with self.subTest(value=value), mock.patch.dict(
                os.environ, {"OLLAMA_THINK": value}
            ):
                self.assertTrue(self.module.Settings().ollama_think)

        for value in ("0", "false", "FALSE", "no", "off"):
            with self.subTest(value=value), mock.patch.dict(
                os.environ, {"OLLAMA_THINK": value}
            ):
                self.assertFalse(self.module.Settings().ollama_think)

        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("OLLAMA_THINK", None)
            self.assertTrue(self.module.Settings().ollama_think)
        with mock.patch.dict(os.environ, {"OLLAMA_THINK": "invalid"}):
            self.assertTrue(self.module.Settings().ollama_think)

    def test_usage_limit_allows_blocks_and_reports_deterministic_retry(self) -> None:
        clock = [100.0]
        limiter = self.module.WindowRateLimiter(
            maximum=2,
            window_seconds=3600,
            clock=lambda: clock[0],
        )
        original_limiter = self.module.message_limiter
        fixed_utc = datetime(2030, 1, 1, tzinfo=timezone.utc)
        chat = self.client.post("/api/chats", json={}).json()["chat"]

        try:
            self.module.message_limiter = limiter
            first = self.client.post(
                f"/api/chats/{chat['id']}/messages",
                json={"content": "First allowed request"},
            )
            clock[0] = 100.5
            second = self.client.post(
                f"/api/chats/{chat['id']}/messages",
                json={"content": "Second allowed request"},
            )
            clock[0] = 101.25
            with mock.patch.object(
                self.module, "_utc_datetime", return_value=fixed_utc
            ):
                blocked = self.client.post(
                    f"/api/chats/{chat['id']}/messages",
                    json={"content": "Blocked request"},
                )

            self.assertEqual(first.status_code, 200)
            self.assertEqual(second.status_code, 200)
            self.assertEqual(blocked.status_code, 429)
            self.assertEqual(blocked.headers["retry-after"], "3599")
            self.assertEqual(
                blocked.json(),
                {
                    "detail": "Usage limit is over. Please try again at the shown time.",
                    "retry_after": 3599,
                    "retry_at": "2030-01-01T00:59:59Z",
                },
            )
            public_error = blocked.text.lower()
            for private_term in ("ollama", "qwen", "model", "provider"):
                self.assertNotIn(private_term, public_error)

            messages_after_block = self.client.get(
                f"/api/chats/{chat['id']}"
            ).json()["messages"]
            self.assertEqual(len(messages_after_block), 4)

            clock[0] = 3700.0
            allowed_again = self.client.post(
                f"/api/chats/{chat['id']}/messages",
                json={"content": "Allowed after the rolling window"},
            )
            self.assertEqual(allowed_again.status_code, 200)
        finally:
            self.module.message_limiter = original_limiter

    def test_forwarded_ip_is_used_only_when_proxy_trust_is_enabled(self) -> None:
        original_limiter = self.module.message_limiter
        original_trust = self.module.settings.trust_proxy
        chat = self.client.post("/api/chats", json={}).json()["chat"]
        client_a = {"X-Forwarded-For": "192.0.2.10, 10.0.0.4"}
        client_b = {"X-Forwarded-For": "198.51.100.8"}

        try:
            self.module.settings.trust_proxy = False
            self.module.message_limiter = self.module.WindowRateLimiter(
                maximum=1, window_seconds=3600, clock=lambda: 10.0
            )
            direct_first = self.client.post(
                f"/api/chats/{chat['id']}/messages",
                json={"content": "Direct client first"},
                headers=client_a,
            )
            direct_second = self.client.post(
                f"/api/chats/{chat['id']}/messages",
                json={"content": "Spoofed forwarded client"},
                headers=client_b,
            )
            self.assertEqual(direct_first.status_code, 200)
            self.assertEqual(direct_second.status_code, 429)

            self.module.settings.trust_proxy = True
            self.module.message_limiter = self.module.WindowRateLimiter(
                maximum=1, window_seconds=3600, clock=lambda: 20.0
            )
            proxy_a = self.client.post(
                f"/api/chats/{chat['id']}/messages",
                json={"content": "Trusted forwarded client A"},
                headers=client_a,
            )
            proxy_b = self.client.post(
                f"/api/chats/{chat['id']}/messages",
                json={"content": "Trusted forwarded client B"},
                headers=client_b,
            )
            proxy_a_again = self.client.post(
                f"/api/chats/{chat['id']}/messages",
                json={"content": "Client A reached its own limit"},
                headers=client_a,
            )
            self.assertEqual(proxy_a.status_code, 200)
            self.assertEqual(proxy_b.status_code, 200)
            self.assertEqual(proxy_a_again.status_code, 429)
            self.assertEqual(proxy_a_again.headers["retry-after"], "3600")
        finally:
            self.module.message_limiter = original_limiter
            self.module.settings.trust_proxy = original_trust

    def test_chat_crud_and_streaming_round_trip(self) -> None:
        created = self.client.post("/api/chats", json={})
        self.assertEqual(created.status_code, 201)
        chat = created.json()["chat"]

        events = []
        with self.client.stream(
            "POST",
            f"/api/chats/{chat['id']}/messages",
            json={"content": "What is 2 + 2?"},
        ) as response:
            self.assertEqual(response.status_code, 200)
            for line in response.iter_lines():
                if line:
                    events.append(json.loads(line))

        self.assertEqual([item["type"] for item in events], ["delta", "delta", "done"])
        answer = "".join(
            item["text"] for item in events if item["type"] == "delta"
        )
        self.assertEqual(answer, "The answer is 4.")

        detail = self.client.get(f"/api/chats/{chat['id']}")
        self.assertEqual(detail.status_code, 200)
        messages = detail.json()["messages"]
        self.assertEqual([message["role"] for message in messages], ["user", "assistant"])
        self.assertEqual(messages[-1]["content"], "The answer is 4.")
        self.assertNotEqual(detail.json()["chat"]["title"], "New conversation")

        renamed = self.client.patch(
            f"/api/chats/{chat['id']}", json={"title": "Quick maths"}
        )
        self.assertEqual(renamed.json()["chat"]["title"], "Quick maths")

        listing = self.client.get("/api/chats").json()["chats"]
        self.assertTrue(any(item["id"] == chat["id"] for item in listing))

        deleted = self.client.delete(f"/api/chats/{chat['id']}")
        self.assertEqual(deleted.status_code, 204)
        self.assertEqual(self.client.get(f"/api/chats/{chat['id']}").status_code, 404)

    def test_live_ollama_readiness_stream_and_safe_errors(self) -> None:
        requests: list[dict] = []

        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/api/tags":
                return httpx.Response(
                    200, json={"models": [{"name": "qwen3:8b"}]}
                )
            self.assertEqual(request.url.path, "/api/chat")
            payload = json.loads(request.content)
            requests.append(payload)
            body = "\n".join(
                [
                    json.dumps(
                        {
                            "message": {
                                "role": "assistant",
                                "thinking": "private reasoning must stay private",
                                "content": "",
                            },
                            "done": False,
                        }
                    ),
                    json.dumps(
                        {
                            "message": {"role": "assistant", "content": "Hello "},
                            "done": False,
                        }
                    ),
                    json.dumps(
                        {
                            "message": {"role": "assistant", "content": "there."},
                            "done": True,
                        }
                    ),
                ]
            ) + "\n"
            return httpx.Response(
                200,
                headers={"Content-Type": "application/x-ndjson"},
                content=body.encode("utf-8"),
            )

        transport = httpx.MockTransport(handler)

        def client_factory(timeout: httpx.Timeout) -> httpx.AsyncClient:
            return httpx.AsyncClient(transport=transport, timeout=timeout)

        async def collect() -> tuple[bool, list[tuple[str, object]]]:
            ready = await self.module._ollama_ready()
            events = [
                event
                async for event in self.module._live_agent_events(
                    [{"role": "user", "content": "Say hello"}]
                )
            ]
            return ready, events

        old_test_mode = self.module.settings.test_mode
        self.module.settings.test_mode = False
        try:
            with mock.patch.object(self.module, "_ollama_client", client_factory):
                ready, events = asyncio.run(collect())
        finally:
            self.module.settings.test_mode = old_test_mode

        self.assertTrue(ready)
        self.assertEqual(events, [("delta", "Hello "), ("delta", "there.")])
        self.assertNotIn("private reasoning", repr(events))
        self.assertEqual(requests[0]["model"], "qwen3:8b")
        self.assertTrue(requests[0]["stream"])
        self.assertTrue(requests[0]["think"])
        self.assertEqual(requests[0]["messages"][-1]["content"], "Say hello")

        async def collect_with_thinking_disabled() -> list[tuple[str, object]]:
            return [
                event
                async for event in self.module._live_agent_events(
                    [{"role": "user", "content": "Be concise"}]
                )
            ]

        old_think = self.module.settings.ollama_think
        self.module.settings.ollama_think = False
        try:
            with mock.patch.object(self.module, "_ollama_client", client_factory):
                disabled_events = asyncio.run(collect_with_thinking_disabled())
        finally:
            self.module.settings.ollama_think = old_think
        self.assertEqual(disabled_events, [("delta", "Hello "), ("delta", "there.")])
        self.assertFalse(requests[-1]["think"])

        error_transport = httpx.MockTransport(
            lambda _: httpx.Response(404, json={"error": "model unavailable"})
        )

        def error_client(timeout: httpx.Timeout) -> httpx.AsyncClient:
            return httpx.AsyncClient(transport=error_transport, timeout=timeout)

        async def collect_error() -> None:
            async for _ in self.module._live_agent_events(
                [{"role": "user", "content": "Hello"}]
            ):
                pass

        with mock.patch.object(self.module, "_ollama_client", error_client):
            with self.assertRaises(self.module.AgentUnavailable) as raised:
                asyncio.run(collect_error())
        public_message = raised.exception.public_message.lower()
        self.assertIn("assistant", public_message)
        self.assertNotIn("ollama", public_message)
        self.assertNotIn("qwen", public_message)

    def test_input_limits_and_unknown_chat_are_safe(self) -> None:
        missing = self.client.post(
            "/api/chats/chat_missing/messages", json={"content": "hello"}
        )
        self.assertEqual(missing.status_code, 404)
        self.assertEqual(missing.json()["detail"], "Conversation not found.")

        invalid = self.client.post("/api/chats", json={"title": "x" * 1000})
        self.assertEqual(invalid.status_code, 422)
        self.assertEqual(
            invalid.json()["detail"], "Check the information and try again."
        )


if __name__ == "__main__":
    unittest.main()

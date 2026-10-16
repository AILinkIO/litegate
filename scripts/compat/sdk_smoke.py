#!/usr/bin/env python3
"""LiteGate 与官方 OpenAI / Anthropic Python SDK 的兼容性冒烟测试。

用法（需要 pip install openai anthropic）：
  LITEGATE_URL=http://127.0.0.1:4000 LITEGATE_API_KEY=lgk-... \\
  OPENAI_ROUTE=glm ANTHROPIC_ROUTE=glm python3 scripts/compat/sdk_smoke.py

OPENAI_ROUTE 用于 /v1/chat/completions 与 /v1/responses，ANTHROPIC_ROUTE 用于 /v1/messages；
路由的上游可以是任意协议（网关负责转换）。任一检查失败时退出码为 1。
"""
import json
import os
import sys

import anthropic
import openai

URL = os.environ.get("LITEGATE_URL", "http://127.0.0.1:4000").rstrip("/")
KEY = os.environ["LITEGATE_API_KEY"]
OA_ROUTE = os.environ.get("OPENAI_ROUTE", "glm")
AN_ROUTE = os.environ.get("ANTHROPIC_ROUTE", OA_ROUTE)

oa = openai.OpenAI(base_url=URL + "/v1", api_key=KEY, timeout=120)
an = anthropic.Anthropic(base_url=URL, api_key=KEY, timeout=120)

WEATHER_OA = {"type": "function", "function": {
    "name": "get_weather", "description": "查询城市当前天气",
    "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}
WEATHER_AN = {"name": "get_weather", "description": "查询城市当前天气",
              "input_schema": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}

results = []


def check(name):
    def wrap(fn):
        try:
            detail = fn()
            results.append((name, True, detail))
        except Exception as e:  # noqa: BLE001 冒烟测试记录任何失败
            results.append((name, False, f"{type(e).__name__}: {e}"[:300]))
        return fn
    return wrap


@check("openai: models.list")
def _():
    ids = [m.id for m in oa.models.list()]
    assert OA_ROUTE in ids, ids
    return f"{len(ids)} models"


@check("openai: chat 同步")
def _():
    r = oa.chat.completions.create(model=OA_ROUTE, max_tokens=2048,
                                   messages=[{"role": "user", "content": "用一个词回答：天空是什么颜色？"}])
    assert r.choices[0].message.content, r
    return f"{r.usage.prompt_tokens}/{r.usage.completion_tokens} tokens"


@check("openai: chat 流式 + usage")
def _():
    text, usage = "", None
    for c in oa.chat.completions.create(model=OA_ROUTE, max_tokens=2048, stream=True,
                                        stream_options={"include_usage": True},
                                        messages=[{"role": "user", "content": "数到三"}]):
        if c.choices and c.choices[0].delta.content:
            text += c.choices[0].delta.content
        if c.usage:
            usage = c.usage
    assert text and usage, (text, usage)
    return f"{len(text)} chars"


@check("openai: 工具调用往返")
def _():
    msgs = [{"role": "user", "content": "北京天气怎么样？请调用工具查询。"}]
    r = oa.chat.completions.create(model=OA_ROUTE, max_tokens=2048, tools=[WEATHER_OA], messages=msgs)
    call = r.choices[0].message.tool_calls[0]
    assert json.loads(call.function.arguments)["city"]
    msgs += [r.choices[0].message.model_dump(exclude_none=True),
             {"role": "tool", "tool_call_id": call.id, "content": "晴，25 摄氏度"}]
    r2 = oa.chat.completions.create(model=OA_ROUTE, max_tokens=2048, tools=[WEATHER_OA], messages=msgs)
    assert r2.choices[0].message.content
    return r2.choices[0].message.content[:40]


@check("openai: responses 同步")
def _():
    r = oa.responses.create(model=OA_ROUTE, input="用一个词回答：草是什么颜色？", max_output_tokens=2048)
    assert r.output_text, r
    return r.output_text[:40]


@check("openai: responses 流式")
def _():
    text, done = "", False
    with oa.responses.stream(model=OA_ROUTE, input="数到三", max_output_tokens=2048) as s:
        for ev in s:
            if ev.type == "response.output_text.delta":
                text += ev.delta
            if ev.type == "response.completed":
                done = True
    assert text and done
    return f"{len(text)} chars"


@check("anthropic: messages 同步")
def _():
    r = an.messages.create(model=AN_ROUTE, max_tokens=2048, messages=[{"role": "user", "content": "用一个词回答：雪是什么颜色？"}])
    assert any(b.type == "text" for b in r.content), r
    return f"{r.usage.input_tokens}/{r.usage.output_tokens} tokens"


@check("anthropic: messages 流式")
def _():
    with an.messages.stream(model=AN_ROUTE, max_tokens=2048, messages=[{"role": "user", "content": "数到三"}]) as s:
        text = "".join(s.text_stream)
        final = s.get_final_message()
    assert text and final.stop_reason
    return f"{len(text)} chars, {final.stop_reason}"


@check("anthropic: 工具调用往返")
def _():
    msgs = [{"role": "user", "content": "上海天气怎么样？请调用工具查询。"}]
    r = an.messages.create(model=AN_ROUTE, max_tokens=2048, tools=[WEATHER_AN], messages=msgs)
    use = next(b for b in r.content if b.type == "tool_use")
    msgs += [{"role": "assistant", "content": [b.model_dump(exclude_none=True) for b in r.content]},
             {"role": "user", "content": [{"type": "tool_result", "tool_use_id": use.id, "content": "多云，22 摄氏度"}]}]
    r2 = an.messages.create(model=AN_ROUTE, max_tokens=2048, tools=[WEATHER_AN], messages=msgs)
    assert r2.stop_reason in ("end_turn", "tool_use"), r2
    return r2.stop_reason


@check("anthropic: count_tokens")
def _():
    r = an.messages.count_tokens(model=AN_ROUTE, messages=[{"role": "user", "content": "hello world"}])
    assert r.input_tokens > 0
    return str(r.input_tokens)


width = max(len(n) for n, _, _ in results)
for name, ok, detail in results:
    print(f"{'OK  ' if ok else 'FAIL'} {name.ljust(width)}  {detail}")
sys.exit(0 if all(ok for _, ok, _ in results) else 1)

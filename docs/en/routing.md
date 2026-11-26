# Routing

English | [简体中文](../routing.md)

## Route matching

The gateway matches the request's model name in this order:

1. Exact route name.
2. Route alias.
3. Wildcard route with the longest prefix.

An API key can restrict which routes it may call, and a route can restrict which API keys may access it. A request goes through only when both sides allow it.

## Targets and fallback

A route contains multiple targets; each target maps the route model to one credential and one upstream model. Targets are grouped by ascending priority,
and ordered within each group by the configured strategy. On a fallback-eligible failure, the next candidate is tried.

Fallback-eligible failures include rate limiting, upstream or gateway timeouts, network errors, upstream credential authentication failures, exhausted quotas and 5xx responses.
4xx responses that indicate the request itself is invalid are returned straight to the client. A streaming request can fall back only before any content has been sent to the client.

## Same-priority strategies

| Strategy | Value | Behavior |
|---|---|---|
| Weighted random | `weighted` | Sampling without replacement by weight |
| In order | `order` | Keep using the first target until it fails or its quota runs out |
| Rotate | `rotate` | Prefer the target with the fewest recent sessions, rotating on ties |
| Least used first | `usage` | Prefer the target with the lowest used fraction of its plan window |
| Earliest reset first | `smart` | When close to exhaustion, prefer the plan credential that resets soonest |
| Weekly pace | `pace` | Choose by remaining plan fraction and remaining time |

The last three strategies rely on available plan quota information. Plain credentials without such information are still ordered by weighted random among themselves.

## Session stickiness

LiteGate identifies sessions from common client request headers and request fields. Stickiness keeps a conversation on the credential that has already answered it whenever possible,
so that the upstream prompt cache is hit.

The default scope keeps stickiness for the current turn; when a new turn starts, it is kept if the cache is still worth it. Route options can widen it to the whole session
or turn stickiness off. An explicitly matched routing rule takes precedence over stickiness.

## Rules and intent routing

Rules run before target selection. A matching rule can send the request to another route, or skip some credentials during specified time windows.

Conditions include:

- Prompt token count.
- Whether images are included or reasoning is enabled.
- Client API format.
- Request tags.
- Local time of day.
- Classified intent.

Intent classification can use a decision model route, a local Laya service or a fallback classification route. A probability below the configured threshold counts as no match.

After 3 consecutive failures, a classifier (classifier / decision_route) is tripped for 30 seconds, during which the current request does not match by intent (when decision_route is tripped,
classifier is asked directly instead); once the period expires, one probe request is let through — success restores it, failure trips it again. Concurrent classifications of the same messages
and intent list call the classifier model only once. After a classification timeout the caller stops waiting, but the classification call keeps running to completion and is logged and billed as usual
(it is forcibly ended only after 60 seconds).

## Concurrency, cooldowns and retries

A credential can have a concurrency limit. When a credential is busy, other targets are preferred; if there are none, the request is queued. A client that disconnects while queued is removed
from the queue immediately; when the concurrency control process restarts, queued requests return immediately instead of blocking forever.

Cooldown durations depend on the failure type. Rate-limit responses use `Retry-After`; exhausted quotas use the reset time returned by the upstream;
authentication, balance and ordinary failures use the configured base duration or an exponentially growing duration. A successful request clears the consecutive failure count.

When every candidate is busy or temporarily unavailable, the gateway can wait and then re-evaluate the route for a full round; the number of rounds and the total wait are bounded by configuration.

# LiteGate 容器镜像：前端 → prod release（含 ERTS）→ slim 运行时
# 数据在 /data（mnesia + bitcask + secret.key），节点名固定 litegate@127.0.0.1（见 config/vm.args）

# ---- 前端（Node 独立阶段，利用层缓存：源码不动时跳过 npm ci）----
FROM node:22-bookworm-slim AS web
WORKDIR /build/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
# tanstackRouter 需要路由目录先就位；构建产物输出到 ../apps/lg_web/priv/static
RUN mkdir -p ../apps/lg_web/priv/static && npm run build

# ---- Erlang 构建（bitcask NIF：CMake + C++23 + libicu）----
FROM erlang:28 AS build
RUN sed -i "s|deb.debian.org|mirrors.aliyun.com|g" /etc/apt/sources.list.d/debian.sources && apt-get update && apt-get install -y --no-install-recommends cmake g++ libicu-dev git libtbb-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY rebar.config rebar.lock ./
COPY config/ config/
COPY apps/ apps/
# 前端产物（上一阶段）就位后再编 release
COPY --from=web /build/apps/lg_web/priv/static apps/lg_web/priv/static
# 构建信息（git commit，构建时通过 --build-arg GIT_SHA 注入；缺省 dev）
ARG GIT_SHA=dev
RUN printf "{\"commit\": \"%s\"}" "$GIT_SHA" > apps/lg_web/priv/build-info.json \
    && cat apps/lg_web/priv/build-info.json
# github 加速（bitcask 等 git 依赖；容器内 github.com 直连不可达时走代理镜像）
RUN git config --global url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"
RUN rebar3 as prod release

# ---- 运行时 ----
# 与构建阶段同为 Debian trixie（erlang:28 基于 trixie，ERTS 依赖 glibc 2.41），libicu 供 bitcask NIF 使用；
# ca-certificates 供上游 HTTPS 校验（public_key:cacerts_get/0 读系统证书，--no-install-recommends 不会随 curl 装上）
FROM debian:trixie-slim
RUN sed -i "s|deb.debian.org|mirrors.aliyun.com|g" /etc/apt/sources.list.d/debian.sources && apt-get update && apt-get install -y --no-install-recommends libicu76 libtbb12 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /data litegate
COPY --from=build /build/_build/prod/rel/litegate /opt/litegate

USER litegate
WORKDIR /data
ENV LITEGATE_DATA_DIR=/data \
    LITEGATE_HTTP_BIND=0.0.0.0 \
    ERL_CRASH_DUMP=/data/erl_crash.dump \
    # crash dump 上限 20MB：故障时 5MB+ 的 dump 不至于撑满磁盘（与 systemd 部署一致）
    ERL_CRASH_DUMP_BYTES=20000000
EXPOSE 4000
VOLUME /data
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
    CMD curl -fsS http://127.0.0.1:${LITEGATE_HTTP_PORT:-4000}/health || exit 1
ENTRYPOINT ["/opt/litegate/bin/litegate", "foreground"]

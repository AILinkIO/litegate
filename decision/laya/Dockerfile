# Laya 本地意图判断服务：ggmlc 的 laya serve（TypeSafe System One 兼容 HTTP API），纯 CPU
# 模型不打进镜像，挂载到 /models（见仓库 README「本地意图判断」）
#
#   docker build -t litegate-laya decision/laya
#   docker run -d --name laya --restart unless-stopped -p 4001:4001 -v ~/app/laya:/models:ro litegate-laya

FROM debian:trixie-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends cmake g++ ninja-build curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG GGMLC_VERSION=0.9.7
# ON：按构建机 CPU 优化（本机实测比通用版快约 30%）；镜像要在别的机器上运行时设为 OFF
ARG GGML_NATIVE=ON
WORKDIR /src
RUN curl -fsSL "https://github.com/monatis/ggmlc/archive/refs/tags/v${GGMLC_VERSION}.tar.gz" | tar xz --strip-components=1
RUN cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=${GGML_NATIVE} \
    && cmake --build build --target laya -j"$(nproc)"

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/examples/laya/laya /usr/local/bin/laya
# 线程数不要超过空闲核数：机器繁忙时线程过多反而慢一个数量级
ENV LAYA_MODEL=/models/laya_multilingual_q8_0.gguf \
    LAYA_PORT=4001 \
    LAYA_THREADS=4
EXPOSE 4001
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD curl -fsS "http://127.0.0.1:${LAYA_PORT}/health" || exit 1
CMD ["sh", "-c", "exec laya serve \"$LAYA_MODEL\" --port \"$LAYA_PORT\" --device cpu --threads \"$LAYA_THREADS\""]

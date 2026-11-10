FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.17.1
ARG ZIG_SHA256_X86_64=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
ARG ZIG_SHA256_AARCH64=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN arch=$(uname -m) \
    && if [ "$arch" = x86_64 ]; then sha=$ZIG_SHA256_X86_64; else sha=$ZIG_SHA256_AARCH64; fi \
    && curl -fsSL -o zig.tar.xz "https://ziglang.org/download/$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz" \
    && echo "$sha  zig.tar.xz" | sha256sum -c - \
    && mkdir /opt/zig && tar -xJf zig.tar.xz -C /opt/zig --strip-components=1 && rm zig.tar.xz
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
COPY scripts ./scripts
COPY autobahn ./autobahn
RUN /opt/zig/zig build -Doptimize=ReleaseSafe -Dtarget="$(uname -m)-linux-musl" --prefix /out

FROM scratch
COPY --from=build /out/bin/quetzal /quetzal
EXPOSE 9001
USER 65534:65534
ENTRYPOINT ["/quetzal"]
CMD ["--bind", "0.0.0.0", "--port", "9001"]

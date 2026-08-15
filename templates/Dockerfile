# syntax=docker/dockerfile:1
#
# Copied from baseline-ops/templates/Dockerfile. It builds any application that
# follows the engineering baseline: one static Go binary, assets embedded,
# ./cmd/server as the main package. Change nothing per project — if a project
# needs a different image, the project is wrong or this template is.

# The build stage is pinned to the build platform and asks Go for the target
# architecture. On the server both are the same, so nothing cross-compiles; the
# form is kept so the same file also builds on an arm64 laptop without QEMU
# emulating the whole toolchain.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build

# git is not a dependency of the code. The toolchain shells out to it to read
# the VCS metadata that stamps info.Main.Version — and golang:alpine ships no
# git. Without this line every deployed binary reports "unknown", silently.
RUN apk add --no-cache git

WORKDIR /src

# Dependencies in their own layer, so a code-only change does not re-download
# the module graph.
COPY go.mod go.sum ./
RUN go mod download

# The whole tree, .git included — see the note above.
COPY . .

ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
    go build -trimpath -o /out/server ./cmd/server

# The state directory is created here because the runtime stage cannot RUN.
RUN mkdir -p /out/state

FROM alpine:3.24

# This stage is pure COPY and metadata on purpose: a RUN here would execute
# target-architecture instructions, which is what forces QEMU emulation the
# moment somebody does build for another platform.
COPY --from=build /out/server /usr/local/bin/server
COPY --from=build --chown=10001:10001 /out/state /var/lib/app

# Where the app finds itself. Everything about how it is *operated* — log level,
# memory limit, prod vs dev — lives in compose.yaml instead. HOST=0.0.0.0 is the
# container's own network, not the internet: the app publishes no host port.
ENV HOST=0.0.0.0 \
    PORT=8080 \
    DATABASE_URL=/var/lib/app/app.db

EXPOSE 8080

# Numeric UID: no adduser, so no RUN in the runtime stage.
USER 10001:10001

# The ops listener the baseline's deployment contract requires. busybox wget
# ships with alpine, which is why this stage is alpine and not scratch.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:6060/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/server"]

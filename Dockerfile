# syntax=docker/dockerfile:1.7

# ---- Build stage ----------------------------------------------------------
# Pin by digest in the final repo (Dependabot keeps it current), e.g.
#   golang:1.24-alpine@sha256:<digest>
FROM golang:1.27-alpine AS build
WORKDIR /src

# Dependency layer first: only re-downloaded when go.mod/go.sum change.
COPY app/go.mod ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

# Source layer. BuildKit cache mounts keep the Go build cache between builds.
COPY app/ ./
ARG VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/app .

# ---- Runtime stage --------------------------------------------------------
# distroless/static: no shell, no package manager, ~2 MB, runs as UID 65532.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER 65532:65532
EXPOSE 8080
ENV PORT=8080
# No HEALTHCHECK: distroless has no curl. Health is probed by the platform
# (Container Apps probes / Kubernetes liveness+readiness on /health, /ready).
ENTRYPOINT ["/app"]

# syntax=docker/dockerfile:1

# ---- Build stage ----
# CGO is required by github.com/mattn/go-sqlite3, so we build with a full toolchain.
FROM golang:1.25-bookworm AS build
ENV CGO_ENABLED=1
WORKDIR /src/whatsapp-bridge

# Cache dependencies first.
COPY whatsapp-bridge/go.mod whatsapp-bridge/go.sum ./
RUN go mod download

# Build the bridge.
COPY whatsapp-bridge/ ./
RUN go build -ldflags="-s -w" -o /out/whatsapp-bridge .

# ---- Runtime stage ----
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /out/whatsapp-bridge /app/whatsapp-bridge
# Ship the knowledge base with the image.
COPY assistant/ /app/assistant/

# The knowledge base path (the code also defaults to ../assistant/knowledge locally).
ENV SOLARTECHY_KB_DIR=/app/assistant/knowledge

# WhatsApp session + local SQLite live here — MOUNT A VOLUME at /app/store.
VOLUME ["/app/store"]

# Internal REST API (send/download). Do NOT expose this publicly — it has no auth.
EXPOSE 8080

CMD ["/app/whatsapp-bridge"]

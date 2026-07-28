# ---- Stage: chef (base común, con cargo-chef instalado) ----
FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef
WORKDIR /app

# ---- Stage: planner (calcula la "receta" de dependencias) ----
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ---- Stage: builder (compila dependencias, después la app) ----
FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
# Esta capa se cachea mientras no cambien las dependencias del Cargo.toml/lock
RUN cargo chef cook --release --recipe-path recipe.json

COPY . .
ENV SQLX_OFFLINE=true
RUN cargo build --release --bin zero2prod

# ---- Stage: runtime (imagen final, mínima) ----
FROM debian:bookworm-slim AS runtime
WORKDIR /app

COPY --from=builder /app/target/release/zero2prod zero2prod
COPY configuration configuration

ENV APP_ENVIRONMENT=production

ENTRYPOINT ["./zero2prod"]

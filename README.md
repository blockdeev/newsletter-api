# zero2prod

Proyecto Rust siguiendo el libro *Zero To Production In Rust*.

> 📌 **Nota:** este README se irá actualizando a medida que avance el proyecto. Por ahora documenta el setup inicial del entorno y del pipeline de CI.

---

## 🛠️ Requisitos previos

Antes de tocar el código, necesitás tener instalado:

- [Rust](https://www.rust-lang.org/tools/install) (vía `rustup`)
- `cargo` (viene incluido con `rustup`)

Rust y Cargo se instalan juntos, pero **algunas herramientas que usamos en este proyecto NO vienen por defecto** y hay que instalarlas aparte.

---

## 📦 Herramientas adicionales a instalar

`rustup` solo instala el compilador (`rustc`) y el gestor de paquetes (`cargo`). Las siguientes herramientas son *subcomandos* de Cargo hechos por la comunidad, y hay que instalarlas manualmente antes de trabajar en este repo:

```bash
cargo install cargo-watch
cargo install cargo-audit
```

| Herramienta | Para qué sirve |
|---|---|
| **cargo-watch** | Recompila y corre el proyecto automáticamente cada vez que guardás un archivo. Ahorra tener que tipear `cargo run` a mano en cada cambio. |
| **cargo-audit** | Escanea las dependencias del proyecto contra una base de datos pública de vulnerabilidades conocidas ([RustSec](https://rustsec.org/)). |

Una vez instaladas, quedan disponibles como comandos de `cargo`:

```bash
cargo watch -x check
cargo audit
```

---

## ⚡ Loop de desarrollo rápido: `cargo check`

Compilar un proyecto Rust completo (`cargo build` o `cargo run`) puede ser lento, porque incluye generar el binario final y linkearlo.

Para iterar rápido mientras programás, usamos:

```bash
cargo check
```

- ✅ Verifica que el código compile (tipos, sintaxis, borrow checker) sin generar el binario final.
- ✅ Es mucho más rápido que un build completo.
- ❌ No genera un ejecutable — no sirve para correr el programa, solo para chequear errores.

Combinado con `cargo-watch`, queda un loop de desarrollo cómodo:

```bash
cargo watch -x check -x test -x run
```

Esto corre, en cada guardado: primero `check` (rápido), después `test`, y si todo pasa, `run`.

---

## 🏗️ Estructura del proyecto

Este proyecto está separado en **librería + binario**, un patrón común en proyectos Rust que exponen una API:

```
zero2prod/
├── src/
│   ├── lib.rs              ← declara los módulos públicos de la librería
│   ├── main.rs              ← entrypoint mínimo: lee config, arma TcpListener + PgPool, arranca el server
│   ├── startup.rs           ← arma App/HttpServer, registra rutas, middlewares y estado compartido (PgPool)
│   ├── configuration.rs     ← lee configuration.yaml y expone los Settings tipados
│   ├── telemetry.rs         ← configura y activa el stack de logging estructurado (tracing)
│   └── routes/
│       ├── mod.rs           ← re-exporta los handlers de cada archivo de ruta
│       ├── health_check.rs  ← handler GET /health_check
│       └── subscriptions.rs ← handler POST /subscriptions
├── migrations/               ← migraciones SQL versionadas (generadas con sqlx-cli)
├── .sqlx/                    ← caché de metadata de queries, para compilar sin conexión a la DB (CI)
├── scripts/
│   └── init_db.sh            ← levanta Postgres en Docker y corre las migraciones
├── tests/
│   └── health_check.rs       ← tests de integración, le pegan a la API por HTTP real
├── configuration.yaml        ← configuración de la app (puerto, datos de conexión a la DB)
└── .env                      ← DATABASE_URL, usado por sqlx en tiempo de compilación
```

¿Por qué separado así? Porque un binario (`main.rs`) no se puede importar como dependencia desde otro archivo. Al mover la lógica a `lib.rs` y sus módulos, los tests en `tests/` pueden hacer `use zero2prod::startup::run` y levantar el servidor real para probarlo end-to-end, tal como lo haría un cliente HTTP externo.

📖 Para una explicación más profunda de los conceptos internos (async, `Future`, el runtime Tokio, extractors, el trait `Service`, HTML forms, migraciones, `Application State`, workers de Actix, `PgPool` vs `PgConnection`, spans y subscribers de `tracing`), ver [`marcoteorico.md`](./marcoteorico.md).

---

## 🌐 Endpoints disponibles

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/health_check` | Devuelve `200 OK` sin body. Usado para verificar que el servidor está vivo. |
| `POST` | `/subscriptions` | Recibe un formulario (`application/x-www-form-urlencoded`) con `name` y `email`, y persiste un nuevo suscriptor en la base de datos. Devuelve `200 OK` si se guardó bien, `400 Bad Request` si faltan campos, `500` si falló la escritura en la DB. |

---

## 🧪 Testing

El proyecto usa **tests de integración**, ubicados en `tests/`, que levantan el servidor real en un puerto aleatorio y le hacen requests HTTP de verdad (con el crate `reqwest`), simulando exactamente lo que haría un cliente externo.

```bash
cargo test
```

Puntos clave de cómo están armados:

- Cada test arranca el servidor con `tokio::spawn`, no con `.await` directo — esto es importante, porque `.await` sobre un servidor bloquearía indefinidamente (los servidores HTTP escuchan para siempre, nunca "terminan" solos).
- Se usa el puerto `0` al hacer el `bind`, lo cual le pide al sistema operativo que asigne un puerto disponible al azar. Esto evita colisiones si corrés varios tests en paralelo, o si el puerto fijo de producción (`8080`) ya está ocupado.
- Cada test crea su **propia base de datos**, con un nombre aleatorio (`uuid`), y corre las migraciones sobre ella antes de arrancar el servidor. Esto aísla los tests entre sí — evita que datos guardados por un test (o una corrida anterior) interfieran con otro. Requiere que Postgres esté corriendo (ver sección de base de datos más abajo).

> ⚠️ Las bases de datos de test no se eliminan automáticamente después de cada corrida (es intencional — Postgres es solo para desarrollo/test). Si se acumulan demasiadas, alcanza con reiniciar el contenedor Docker.

---

## 📊 Telemetría y logging estructurado

La aplicación emite logs estructurados en formato **JSON**, con soporte para trazar cada request de punta a punta.

### Configuración

Todo el stack de logging se arma en `src/telemetry.rs` (`get_subscriber` + `init_subscriber`), y se activa una sola vez, tanto en `main.rs` como en `tests/health_check.rs`.

### Controlar el nivel de detalle

```bash
RUST_LOG=debug cargo run
```

Por defecto, si no se setea `RUST_LOG`, se usa el nivel `info`.

### Ver logs durante un test específico

Por defecto, los tests corren en silencio (los logs van a `std::io::sink`). Para verlos:

```bash
TEST_LOG=true cargo test health_check_works -- --nocapture
```

### Cada request queda correlacionado con un `request_id`

Gracias al middleware `TracingLogger` (de `tracing-actix-web`), todos los logs generados durante el procesamiento de un mismo request HTTP —incluyendo los que emite la lógica de negocio internamente— comparten el mismo `request_id`. Esto permite reconstruir la historia completa de un request puntual (qué datos llegaron, qué falló, qué se devolvió) buscando por ese único identificador.

📖 Qué es un *span*, qué es un *subscriber*, y por qué la instrumentación de desarrollo/test es la misma que corre en producción: ver [`marcoteorico.md`](./marcoteorico.md).

---

## 🐘 Base de datos (PostgreSQL + Docker)

Este proyecto persiste los suscriptores en una base de datos PostgreSQL. Para desarrollo local se usa un contenedor Docker, sin necesidad de instalar Postgres directamente en el sistema.

### Requisitos

- Docker (Docker Desktop o el daemon de Docker corriendo) — no hace falta usar la interfaz gráfica, todo se maneja por línea de comandos.
- Cliente `psql`: `sudo apt install postgresql-client`
- `sqlx-cli`, para gestionar migraciones:
  ```bash
  cargo install sqlx-cli --no-default-features --features rustls,postgres
  ```

### Levantar la base de datos

```bash
./scripts/init_db.sh
```

Este script:
1. Verifica que `psql` y `sqlx` estén instalados.
2. Levanta un contenedor Docker con Postgres (usuario, password, puerto y nombre de DB configurables vía variables de entorno, con valores por defecto).
3. Espera hasta que Postgres esté listo para aceptar conexiones.
4. Crea la base de datos y corre las migraciones pendientes (`migrations/`).

Si ya tenés un Postgres dockerizado corriendo (por ejemplo, de una corrida anterior) y solo querés crear la DB/correr migraciones sin levantar un contenedor nuevo:

```bash
SKIP_DOCKER=true ./scripts/init_db.sh
```

### Migraciones

Cada cambio de esquema de la base de datos vive como un archivo `.sql` versionado en `migrations/`. Para agregar una nueva:

```bash
sqlx migrate add <nombre_descriptivo>
```

📖 Más sobre qué son las migraciones y por qué se usan, en [`marcoteorico.md`](./marcoteorico.md).

### Verificar la conexión (opcional)

```bash
PGPASSWORD=password psql -h localhost -U postgres -p 5432 -d newsletter -c '\dt'
```

---

## 📦 Dependencias principales de la aplicación

| Crate | Para qué lo usamos |
|---|---|
| `actix-web` | Framework web: routing, extractors, servidor HTTP |
| `serde` (con `derive`) | (De)serialización — convierte el body de los requests (forms) en structs de Rust tipados |
| `sqlx` (`runtime-tokio`, `tls-rustls-ring-webpki`, `macros`, `postgres`, `uuid`, `chrono`, `migrate`) | Cliente async de PostgreSQL, con validación de queries SQL en tiempo de compilación |
| `config` | Lee `configuration.yaml` y lo convierte en structs tipados (`Settings`) |
| `uuid` (feature `v4`) | Genera identificadores únicos (`id` de cada suscriptor) |
| `chrono` | Maneja timestamps (`subscribed_at`) |
| `tracing` | Instrumentación: macros y el concepto de `Span` para representar unidades de trabajo |
| `tracing-subscriber` (`registry`, `env-filter`) | Arma el pipeline que procesa los spans/eventos y filtra por nivel (`RUST_LOG`) |
| `tracing-bunyan-formatter` | Formatea los logs como JSON estructurado |
| `tracing-log` | Redirige logs de dependencias que usan `log` (como `actix-web`) hacia el mismo pipeline de `tracing` |
| `tracing-actix-web` | Middleware `TracingLogger`: genera un `request_id` consistente por cada request HTTP |
| `secrecy` (feature `serde`) | Envuelve el password de la base de datos (`SecretString`) para que no se filtre en logs por accidente |

📖 El porqué de elegir una base de datos relacional, por qué Postgres puntualmente, y por qué `sqlx` sobre otras alternativas del ecosistema Rust, están explicados en [`marcoteorico.md`](./marcoteorico.md).

---

Estas solo se compilan al correr `cargo test`, no forman parte del binario final:

| Crate | Para qué |
|---|---|
| `reqwest` (con `rustls`, no TLS nativo) | Cliente HTTP para simular requests reales contra la API en los tests |
| `tokio` (features `macros`, `rt-multi-thread`) | Habilita `#[tokio::test]` y `tokio::spawn` para correr el servidor en background durante los tests |

> 💡 Usamos `rustls` en vez del TLS nativo del sistema para evitar depender de OpenSSL/`pkg-config` instalados a nivel del sistema operativo — hace que el proyecto compile igual en cualquier máquina, sin pasos de instalación extra.

---

## ✅ CI Pipeline (GitHub Actions)

Este repo corre chequeos automáticos en cada `push` y `pull request`, usando GitHub Actions. Los workflows viven en `.github/workflows/`.

### `general.yml`

Corre tres jobs:

- **Test** → corre la suite de tests (`cargo test --all-features`) contra un **Postgres real**, levantado como *service container* dentro del propio job. Antes de testear, instala `sqlx-cli` y corre las migraciones.
- **Rustfmt** → verifica que el código esté formateado según el estándar de Rust (`cargo fmt --check`). No compila nada, así que no necesita base de datos.
- **Clippy** → corre el linter oficial de Rust (`cargo clippy`), usando `SQLX_OFFLINE=true`. En vez de conectarse a una base de datos real para validar las queries de `sqlx::query!`, usa el caché de metadata guardado en `.sqlx/`.

> ⚠️ **Sobre el caché `.sqlx/`**: cada vez que se agregue o modifique una query con `sqlx::query!`/`sqlx::query!` en `src/`, hay que regenerar el caché (con Postgres corriendo localmente):
> ```bash
> export DATABASE_URL="postgres://postgres:password@localhost:5432/newsletter"
> cargo sqlx prepare
> git add .sqlx/
> ```
> Si no se regenera, el job de `clippy` va a fallar con *"there is no cached data for this query"*.
>
> El job `test` **no** usa el caché — corre contra una base de datos real, así que siempre valida las queries de forma genuina, incluidas las que viven en `tests/` (que `cargo sqlx prepare` no escanea).

### `audit.yml`

Corre `cargo-audit` directamente (instalado en el runner) para detectar vulnerabilidades conocidas en las dependencias. Se dispara:

- Cada vez que cambia `Cargo.toml` o `Cargo.lock`.
- Una vez al día, de forma programada (por si aparece una vulnerabilidad nueva en una dependencia que ya estaba en el proyecto).
- Manualmente, desde la pestaña **Actions** de GitHub (`workflow_dispatch`).

> Podés ver el resultado de cada corrida en la pestaña **Actions** del repositorio en GitHub.

---

## 🚀 Cómo levantar el proyecto localmente

```bash
git clone git@github.com:blockdeev/zero2prod.git
cd zero2prod

# 1. Levantar la base de datos (Docker + migraciones)
./scripts/init_db.sh

# 2. Levantar la app
cargo watch -x check -x test -x run
```

El servidor queda escuchando en `http://127.0.0.1:8080` (puerto leído desde `configuration.yaml`). Podés probar el health check con:

```bash
curl -v http://127.0.0.1:8080/health_check
```

Y crear un suscriptor con:

```bash
curl -v -X POST http://127.0.0.1:8080/subscriptions \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "name=le%20guin&email=ursula_le_guin%40gmail.com"
```

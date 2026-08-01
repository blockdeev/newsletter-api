# 📚 Marco Teórico — Async, Futures, Tokio y Actix Web

> 🎯 **Objetivo de este documento:** explicar qué pasa "detrás de escena" cuando corremos nuestra API en Rust con Actix Web, conectando la teoría del libro *Zero To Production In Rust* (que usa sintaxis de 2022) con el código moderno del proyecto (macros de atributo, extractors, etc.).
>
> 📌 Complementa a `README.md` — ahí está el setup del proyecto, acá está la teoría detrás del código.

---

## 🗺️ Mapa general: qué pasa cuando llega un request

```
   Request HTTP llega
          │
          ▼
   ┌─────────────────┐
   │   HttpServer     │  ← maneja TCP / TLS / conexiones concurrentes
   └────────┬─────────┘
            ▼
   ┌─────────────────┐
   │       App        │  ← busca qué handler matchea la ruta
   └────────┬─────────┘
            ▼
   ┌─────────────────┐
   │   Extractors      │  ← resuelve los parámetros del handler (Path, Json, etc.)
   └────────┬─────────┘
            ▼
   ┌─────────────────┐
   │  Handler (async)  │  ← se ejecuta como una Future
   └────────┬─────────┘
            ▼
   ┌─────────────────┐
   │  Tokio (runtime)  │  ← hace "poll" de la Future hasta resolverla
   └────────┬─────────┘
            ▼
   ┌─────────────────┐
   │    Responder      │  ← convierte el resultado en HttpResponse
   └────────┬─────────┘
            ▼
      Response al cliente
```

---

## 1️⃣ `HttpServer` — el motor de transporte

`HttpServer` es la pieza que se encarga de **todo lo relacionado a la conexión física**, no de la lógica de negocio:

| Se encarga de... | Ejemplo |
|---|---|
| 🔌 Dónde escuchar | IP + puerto (`127.0.0.1:8080`), o un socket Unix |
| 🚦 Concurrencia | Cuántas conexiones simultáneas se permiten |
| 🔒 Seguridad de transporte | Habilitar o no TLS |

```rust
HttpServer::new(|| App::new().service(index).service(hello))
    .bind(("127.0.0.1", 8080))?
    .run()
    .await
```

> 💡 Esto **no cambió** entre la versión del libro y la versión moderna — sigue siendo exactamente el mismo rol.

---

## 2️⃣ `App` — donde vive la lógica

`App` es un **builder pattern**: se arma encadenando métodos (`.service()`, `.route()`, `.wrap()` para middlewares, etc.), empezando de una base vacía con `App::new()`.

Su trabajo: **tomar un request y devolver una response**, decidiendo internamente a qué handler mandarlo.

---

## 3️⃣ Routing: estilo libro vs. estilo moderno

### 📖 Como lo enseña el libro (routing manual)

```rust
App::new()
    .route("/", web::get().to(greet))
    .route("/{name}", web::get().to(greet))
```

### ⚡ Como lo escribimos hoy (macros de atributo)

```rust
#[get("/")]
async fn index() -> impl Responder {
    "Hello, World!"
}

App::new().service(index)
```

> ✅ **Son equivalentes.** `#[get("/")]` es una *macro procedural* que, en tiempo de compilación, genera automáticamente el mismo patrón `Route` + `Guard` que el libro escribe a mano.

### 🔬 Prueba real (con `cargo expand`)

Expandiendo el macro, se confirma que genera exactamente esto por detrás:

```rust
let __resource = ::actix_web::Resource::new("/")
    .name("index")
    .guard(::actix_web::guard::Get())
    .to(index);
```

Es decir: la macro **no reemplaza el concepto de `Guard`** que enseña el libro (una condición que el request debe cumplir para matchear, como "ser método GET") — solo lo escribe automáticamente por nosotros.

---

## 4️⃣ Handlers y Extractors 🧩

Un **handler** es la función que procesa un request específico. El libro empieza con una única firma posible:

```rust
async fn greet(req: HttpRequest) -> impl Responder {
    let name = req.match_info().get("name").unwrap_or("World");
    format!("Hello {}!", &name)
}
```

Actix permite firmas mucho más flexibles gracias a los **extractors**:

```rust
async fn hello(name: web::Path<String>) -> impl Responder {
    format!("Hello {}!", &name)
}
```

### 🧠 ¿Qué es un extractor?

Un tipo que implementa el trait `FromRequest`. Cuando un handler pide un extractor como parámetro, Actix automáticamente:

1. 🔍 Mira la parte relevante del request (URL, body, query string...)
2. ✂️ Extrae el dato correspondiente
3. 🔄 Intenta convertirlo al tipo pedido
4. ⚠️ Si falla, devuelve un `400 Bad Request` solo, sin que escribamos ese manejo de error

| Extractor | Extrae de... |
|---|---|
| `web::Path<T>` | Segmentos dinámicos de la URL (`/{name}`) |
| `web::Json<T>` | Body en formato JSON |
| `web::Query<T>` | Query string (`?page=2`) |
| `web::Data<T>` | Estado compartido de la aplicación |

---

## 5️⃣ ¿Por qué `main` no puede ser `async` directamente? ⚙️

Esto es el corazón conceptual del capítulo. Tres datos clave:

> 🔑 **Dato 1:** Una `Future` en Rust es un valor que **puede no estar listo todavía**. Necesita que algo la "polee" (`.poll()`) repetidamente para avanzar y resolverse.

> 🔑 **Dato 2:** Las futures son **lazy** — si nadie las poll-ea, nunca se ejecutan. Es un modelo *pull*, no *push*.

> 🔑 **Dato 3:** La librería estándar de Rust **no trae un runtime asíncrono incluido**, a propósito. Hay que traer uno como dependencia (Tokio, en nuestro caso).

Como no existe un runtime "oficial" reconocido por el compilador, Rust no sabe quién va a poll-ear un `main` async — por eso **no está permitido**:

```
error: `main` function is not allowed to be `async`
```

### La solución: una macro que arma todo por nosotros

| Versión | Macro |
|---|---|
| 📖 Libro | `#[tokio::main]` |
| ⚡ Proyecto actual | `#[actix_web::main]` |

Ambas expanden a algo equivalente a:

```rust
fn main() -> std::io::Result<()> {
    // arranca el runtime y bloquea el hilo principal
    // hasta que la Future se resuelva
    runtime.block_on(async {
        // tu código async original
    })
}
```

### 🔬 Prueba real, con nuestro propio `cargo expand`

```rust
fn main() -> std::io::Result<()> {
    <::actix_web::rt::System>::new()
        .block_on(async move {
            HttpServer::new(|| App::new().service(index).service(hello))
                .bind(("127.0.0.1", 8080))?
                .run()
                .await
        })
}
```

> 🎉 **Confirmado:** `#[actix_web::main]` no reemplaza a Tokio — lo esconde. `actix_web::rt::System` es un wrapper propio de Actix que **usa Tokio por debajo**. Tokio nunca se fue, solo quedó invisible detrás de la macro.

---

## 6️⃣ Cada `async fn` es una Future 🔮

```rust
#[get("/")]
async fn index() -> impl Responder {
    "Hello, World!"
}
```

Cuando el compilador ve `async fn`, **no genera una función normal**. Genera un **tipo anónimo que implementa `Future`**, con:
- El estado necesario para ejecutar el cuerpo paso a paso
- Un método `.poll()` que avanza ese estado

📌 **Cada handler genera su propia Future, independiente de las demás**, cada vez que se invoca:

- `index()` → nueva Future cada vez que llega un `GET /`
- `hello(name)` → nueva Future cada vez que llega un `GET /{name}`

Esto es lo que le permite a Tokio manejar **miles de conexiones concurrentes con pocos threads reales**: mientras una Future está "esperando" algo (ej. una consulta a base de datos), le cede el control a otra en vez de bloquear el thread.

---

## 7️⃣ ⚠️ Corrección importante: encadenar `.service()` NO ejecuta nada

```rust
App::new().service(index).service(hello)
```

Esto **no llama** a `index` ni a `hello`. Es **configuración**, no ejecución — arma una tabla interna de rutas: *"si llega algo a `/`, usar `index`; si llega algo a `/{name}`, usar `hello`"*.

### 🔄 El ciclo real

1. `HttpServer.run().await` arranca y **se queda escuchando indefinidamente**
2. Llega un request → Actix busca en la tabla cuál ruta matchea
3. **Recién ahí** se invoca el handler correspondiente, generando su Future
4. Se resuelve, se responde, y el servidor vuelve a esperar

> ✅ Un handler se puede llamar **0, 1, o miles de veces** — no una sola vez "porque está encadenado". El encadenamiento es tiempo de configuración (una sola vez, al armar la app); la ejecución del handler es tiempo de request (una y otra vez, mientras el server esté vivo).

---

## 8️⃣ ¿Qué es un `Service`? 🧱

Concepto central en el diseño de Actix — mucho más que "el método `.service()`".

```rust
trait Service<Request> {
    type Response;
    type Error;
    type Future: Future<Output = Result<Self::Response, Self::Error>>;

    fn call(&self, req: Request) -> Self::Future;
}
```

En criollo: **"algo que recibe un request y devuelve, de forma asíncrona, una response (o un error)"**.

### 🧩 Por qué es poderoso

Como *todo* implementa este mismo trait (un handler, un middleware, toda la `App`), se pueden **envolver unos dentro de otros**. Así funcionan los middlewares (logging, auth, CORS): son `Service`s que envuelven a otro `Service` interno.

```
Middleware A
   └── Middleware B
         └── Handler real (Service final)
```

### 🏭 Qué hace `.service(index)` puntualmente

Registra una **factory** (`HttpServiceFactory`) — no crea el `Service` en el momento, le da a `App` la receta para construirlo cuando haga falta (por ejemplo, cada worker thread arma su propia copia).

### ⚠️ Aclaración importante: `Service` es tiempo de compilación, Tokio opera en tiempo de ejecución

Es fácil confundir estas dos capas, así que vale la pena separarlas con claridad:

> 🔑 **`Service` es solo una interfaz** (un trait) que el compilador usa para verificar tipos. Que un handler, un middleware o `App` "implementen `Service`" significa que el compilador puede chequear, en **tiempo de compilación**, que todos comparten la misma forma: *"recibo un request, devuelvo (async) una response"*. Es pura organización de código — el compilador verifica que todo encaje, y arma las estructuras necesarias.

> 🔑 **Tokio no "maneja" `Service`s — maneja `Future`s.** Tokio es agnóstico a esta abstracción: es una capa de Actix, no de Tokio. Lo único que le importa a Tokio, un nivel más abajo, son las **futures**.

Fijate bien en la firma del trait:

```rust
trait Service<Request> {
    type Future: Future<Output = Result<Self::Response, Self::Error>>;
    fn call(&self, req: Request) -> Self::Future;
}
```

El método `.call()` de un `Service` **devuelve una `Future`**. La cadena real de eventos es:

1. 🛠️ **Tiempo de compilación** → el compilador verifica que tu handler/middleware/`App` cumplan con el trait `Service` (tipos y firmas correctas).
2. 🌐 **Tiempo de ejecución** → cuando llega un request real, Actix llama a `.call(req)` sobre el `Service` correspondiente, lo cual **produce una Future**.
3. ⚙️ **Ahí entra Tokio** → el runtime toma esa Future y la poll-ea hasta que se resuelve.

| Capa | Qué representa | Quién la usa |
|---|---|---|
| `Service` (trait) | Contrato/estructura, un contrato de tipos | El **compilador**, en tiempo de compilación |
| `Future` | Lo que efectivamente se ejecuta y se resuelve | **Tokio**, en tiempo de ejecución (polling, scheduling) |

> ✅ Tokio no "sabe" ni le importa que algo implemente `Service` — solo le importan las `Future`s que ese `Service` termina produciendo cuando se lo invoca.

---

## 9️⃣ Librería + binario: por qué separamos el proyecto en dos crates 📦

Hasta ahora todo el código vivía en `src/main.rs`, compilado como **binario**. Esto tiene un límite importante cuando queremos escribir tests de integración.

### El problema

Los tests en la carpeta `tests/` se compilan como **binarios separados**, con exactamente el mismo nivel de acceso que tendría alguien que importa nuestro proyecto como dependencia (`use newsletter_api::algo`). Pero **un binario no se puede importar como dependencia** — solo las librerías (`lib`) se pueden importar con `use`. Si toda la lógica vive únicamente en `main.rs`, los tests en `tests/` no tienen a qué apuntar: no existe ningún `newsletter_api::algo` al que hacer `use`, porque no hay ninguna librería, solo un ejecutable aislado.

### La solución: dos crates en el mismo `Cargo.toml`

```toml
[lib]
path = "src/lib.rs"

[[bin]]
path = "src/main.rs"
name = "newsletter-api"
```

```
src/
├── lib.rs      ← TODA la lógica real vive acá (App, HttpServer, handlers, routing)
└── main.rs      ← "entrypoint fino": solo arranca lo que expone lib.rs
```

### Cómo queda `main.rs`

```rust
use std::net::TcpListener;
use newsletter_api::run;

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let listener = TcpListener::bind("127.0.0.1:8080")
        .expect("Failed to bind random port");
    run(listener)?.await
}
```

Literalmente eso — arma un listener, se lo pasa a `run()` (que vive en la librería), y lo ejecuta.

### Por qué vale la pena, en concreto

| Beneficio | Explicación |
|---|---|
| 🧪 Habilita testing real | Sin esto, no hay ningún punto de entrada al que los tests en `tests/` puedan engancharse |
| 🛡️ `main.rs` casi imposible de romper | Cuanta menos lógica tenga el binario, menos cosas pueden fallar ahí — toda la complejidad vive en un lugar testeable |
| ♻️ Reutilización | Si mañana se necesitara un segundo binario (por ejemplo, un CLI de administración), ambos podrían importar la misma librería sin duplicar código |

---

## 🔟 Concurrencia real: dentro de UNA task vs. entre VARIAS tasks 🐢🐇

Este es un punto que suele confundir, así que vale la pena remarcarlo con cuidado — tiene que ver con una idea errónea común: *"Rust maneja la concurrencia automáticamente, así que un `.await` nunca debería bloquear nada más"*. Eso **no es del todo cierto**.

### Lo que Rust SÍ hace bien

Cuando una `Future` está esperando algo, el runtime no bloquea el *thread del sistema operativo* completo — puede cederle el procesador a **otras tasks** que también estén registradas con él.

### El matiz importante: "otras tasks" no aparecen solas

El runtime solo puede intercalar trabajo entre tasks que **ya existen**. Si escribimos código con varios `.await` en secuencia, dentro de la misma función, eso es **una sola task**, y dentro de ella no hay concurrencia:

```rust
async fn spawn_app() -> std::io::Result<()> {
    newsletter_api::run().await   // (A) bloquea el avance de ESTA task hasta resolverse
}

async fn health_check_works() {
    spawn_app().await;       // (B) nunca se llega acá si (A) no termina
    let client = /* ... */;  // (C) tampoco
}
```

`.await` significa **"no avances más allá de este punto hasta que esta future se resuelva"** — dentro de una misma cadena secuencial, eso es indistinguible de código síncrono normal. El hecho de que el runtime *podría* aprovechar el thread libre para otra task no ayuda en nada acá, porque no existe ninguna otra task corriendo en paralelo.

### Cómo se crea concurrencia real: `tokio::spawn`

```rust
fn spawn_app() {
    let server = newsletter_api::run().expect("Failed to bind address");
    let _ = tokio::spawn(server);   // ← crea una NUEVA task, independiente
}
```

`tokio::spawn(server)` le entrega esa future al runtime como una **task aparte**, sin esperar su resultado (a diferencia de `.await`, que sí espera). Por eso `spawn_app()` retorna casi al instante — nunca esperó a que el servidor "termine" (y un servidor HTTP, por diseño, nunca termina solo).

### 🐢🐇 Metáfora para recordarlo

- **Una task con varios `.await` en secuencia** = una persona haciendo una fila de trámites, uno detrás del otro. Si el trámite 1 nunca termina, nunca llega al trámite 2.
- **Varias tasks (`tokio::spawn`)** = varias personas en filas distintas, todas atendidas por el mismo edificio (el runtime), que va salteando entre ventanillas cuando alguna persona queda esperando algo.

> ✅ **Regla general:** dentro de una misma cadena de `.await` secuenciales, cada `.await` bloquea el avance de *esa* task. La concurrencia real entre piezas de trabajo distintas solo aparece cuando explícitamente creamos tasks separadas (`tokio::spawn`) o usamos combinadores como `join!`/`select!`.

---

## 1️⃣1️⃣ Puerto `0`: dejar que el sistema operativo elija 🎲

### El problema de usar un puerto fijo en los tests

```rust
TcpListener::bind("127.0.0.1:8080")
```

Si el puerto está *hardcodeado*, dos problemas concretos aparecen:

- Si el puerto ya está en uso (por ejemplo, por nuestra propia app corriendo con `cargo run` en otra terminal), el test falla.
- Si corremos varios tests en paralelo (comportamiento por defecto de `cargo test`), todos menos uno van a fallar tratando de tomar el mismo puerto.

### La solución: puerto `0`

```rust
let listener = TcpListener::bind("127.0.0.1:0")
    .expect("Failed to bind random port");
let port = listener.local_addr().unwrap().port();
```

El puerto `0` está **especialmente tratado a nivel del sistema operativo**: pedirle al SO que "bindee" el puerto `0` dispara una búsqueda automática de un puerto disponible, que luego se asigna a la aplicación. `listener.local_addr().unwrap().port()` nos devuelve **cuál fue el puerto real** que el SO asignó, para poder construir la URL completa y usarla en el test:

```rust
format!("http://127.0.0.1:{port}")
```

> 💡 Este patrón resuelve el problema de raíz, sin necesidad de coordinar manualmente qué puerto usa cada test — cada corrida de `cargo test` obtiene puertos frescos, sin colisiones.

### ⚠️ ¿Por qué entonces `main.rs` usa un puerto fijo (`8080`) y no `0`?

Vale la pena remarcar esta diferencia, porque a primera vista podría parecer inconsistente:

```rust
// main.rs — puerto FIJO
TcpListener::bind("127.0.0.1:8080")

// tests/health_check.rs — puerto ALEATORIO
TcpListener::bind("127.0.0.1:0")
```

Son dos escenarios con necesidades opuestas:

| | `main.rs` (producción) | `tests/` (testing) |
|---|---|---|
| **¿Quién necesita conocer el puerto?** | Clientes externos reales (navegador, `curl`, otro servicio, un balanceador de carga) | Solo el propio test, que ya lo descubre en runtime con `local_addr()` |
| **¿Se ejecuta una sola vez o muchas en paralelo?** | Una sola instancia corriendo de forma continua | Potencialmente decenas de tests corriendo en paralelo en la misma corrida de `cargo test` |
| **¿Importa que el puerto sea predecible?** | Sí — un cliente necesita saber de antemano a qué puerto conectarse (o depender de configuración/DNS que apunte a un puerto conocido) | No — cada test arma su propia URL dinámicamente, nadie externo necesita adivinarla |

En producción, un puerto aleatorio sería un problema: ¿cómo le decís al mundo exterior a qué puerto conectarse si cambia cada vez que reiniciás el servidor? Por eso se usa un puerto **fijo y conocido**, típicamente documentado o configurable (más adelante en el libro esto se vuelve configurable vía archivo de configuración, en vez de estar hardcodeado).

En testing, en cambio, el puerto es un **detalle interno y descartable**: el propio test lo pide, lo descubre (`local_addr().unwrap().port()`), arma la URL, y la usa — nadie más necesita saber cuál fue. Como además `cargo test` puede correr múltiples tests en paralelo por defecto, usar un puerto fijo ahí garantizaría colisiones; el puerto aleatorio es lo que hace posible esa paralelización sin conflictos.

> ✅ **En una frase:** el puerto fijo sirve para que el mundo exterior pueda encontrar al servidor; el puerto aleatorio sirve para que los tests no se estorben entre sí.

---

## 1️⃣2️⃣ `rustls` vs. TLS nativo: evitar depender de OpenSSL del sistema 🔒

Al agregar `reqwest` como dependencia de test (para hacer requests HTTP reales contra nuestra API), aparece una decisión de diseño relevante: **qué implementación de TLS usar**.

### El problema con la opción por defecto

Por defecto, `reqwest` usa el **TLS nativo del sistema operativo** — en Linux, eso significa compilar/enlazar contra **OpenSSL**, lo cual requiere tener `pkg-config` y las librerías de desarrollo de OpenSSL (`libssl-dev`) instaladas en la máquina. Si faltan, la compilación falla con errores como:

```
Could not find directory of OpenSSL installation...
```

### La alternativa: `rustls`

```bash
cargo add reqwest --dev --no-default-features --features rustls
```

`rustls` es una implementación de TLS **escrita íntegramente en Rust**, sin dependencias del sistema operativo. Se compila igual en cualquier máquina — la nuestra, la de un compañero de equipo, o el runner de GitHub Actions — sin pasos de instalación adicionales.

| | TLS nativo (OpenSSL) | `rustls` |
|---|---|---|
| Dependencias del sistema | Sí (`pkg-config`, `libssl-dev`) | No |
| Portabilidad | Puede fallar según el SO/distro | Compila igual en cualquier lado |
| Origen del código | C (OpenSSL) | Rust puro |

> ✅ Preferimos `rustls` por portabilidad: elimina una categoría entera de errores de compilación relacionados al entorno, tanto en desarrollo local como en CI.

---

## 1️⃣3️⃣ HTML Forms, el extractor `web::Form` y el trait `FromRequest` 📝

### Cómo llegan los datos de un formulario

Cuando un navegador envía un formulario HTML sin JavaScript de por medio, el body del request tiene el `Content-Type: application/x-www-form-urlencoded`, con un formato tipo:

```
name=le%20guin&email=ursula_le_guin%40gmail.com
```

Pares `clave=valor` separados por `&`, con caracteres especiales *percent-encoded* (`%20` = espacio, `%40` = `@`).

### El extractor `web::Form<T>`

Ya vimos el concepto general de extractor (sección 4) — `web::Form<T>` es una instancia concreta, especializada en este formato:

```rust
#[derive(serde::Deserialize)]
pub struct FormData {
    email: String,
    name: String,
}

#[post("/subscriptions")]
pub async fn subscribe(form: web::Form<FormData>) -> impl Responder {
    // form.email, form.name ya están parseados y tipados
}
```

Como cualquier extractor, `web::Form<T>` implementa `FromRequest`. Cuando llega el request:

1. Verifica que el `Content-Type` sea `application/x-www-form-urlencoded`.
2. Parsea el body como pares clave-valor.
3. Usa `serde::Deserialize` (por eso el `#[derive(Deserialize)]` en `FormData`) para convertir esos pares en una instancia de tu struct.
4. Si falta algún campo requerido, o el tipo no matchea, la extracción falla — y Actix devuelve automáticamente un `400 Bad Request`, **sin que tu handler llegue a ejecutarse**.

> ✅ Esto es lo que hace que nuestros tests `subscribe_returns_a_400_when_data_is_missing` pasen sin escribir ninguna validación manual — la validación de "¿están todos los campos?" la hace el extractor, antes de que tu código de negocio corra.

---

## 1️⃣4️⃣ ¿Por qué una base de datos relacional? ¿Por qué Postgres? 🐘

### Por qué relacional

El libro justifica esta elección con el tipo de datos que vamos a manejar: registros de suscriptores, con relaciones futuras (por ejemplo, suscriptores vinculados a confirmaciones de email, a newsletters enviadas, etc.). Una base de datos relacional da:

- **Garantías de integridad fuertes**: constraints como `UNIQUE` (el email no se puede repetir) y `NOT NULL` se aplican a nivel de la base de datos, no solo en el código de la aplicación — una capa extra de seguridad, independiente de bugs en el código Rust.
- **Transacciones ACID**: operaciones que se aplican todas o ninguna, útil a medida que el sistema crezca en complejidad (por ejemplo, registrar un suscriptor y encolar un email de confirmación de forma atómica).
- **Un modelo de datos maduro y bien entendido**, con décadas de herramientas, tooling y prácticas alrededor.

### Por qué Postgres puntualmente

El libro elige Postgres (en vez de MySQL, SQLite, u otras) por:

- Es **open source**, gratuito, y ampliamente adoptado en la industria — mucha documentación y soporte comunitario.
- Tiene un **ecosistema Rust maduro**: los drivers y crates disponibles para Postgres (como `sqlx`) suelen ser los más completos y activamente mantenidos del ecosistema.
- Soporta **tipos de datos ricos** (UUID nativo, JSON, arrays, etc.) que encajan bien con lo que necesitamos (por ejemplo, la columna `id uuid` de nuestra tabla `subscriptions`).

---

## 1️⃣5️⃣ ¿Por qué `sqlx` y no otra librería? 🦀

El ecosistema Rust tiene varias opciones para hablar con bases de datos. Las alternativas más conocidas junto a `sqlx` son `diesel` (un ORM) y `tokio-postgres` (un driver de bajo nivel). El libro elige `sqlx` por una combinación de características poco común:

| Característica | Qué aporta |
|---|---|
| **Async nativo** | A diferencia de `diesel` (que históricamente era síncrono), `sqlx` es async desde el diseño — encaja naturalmente con Actix Web/Tokio |
| **Sin ORM, SQL directo** | No hay una capa de abstracción que "traduzca" tu código a SQL — escribís SQL real, dentro de macros como `sqlx::query!` |
| **Validación en tiempo de compilación** | `sqlx::query!` se conecta a la base de datos real durante `cargo build`/`cargo check` para verificar que la consulta sea válida (columnas existentes, tipos compatibles) — errores de SQL se detectan **antes** de correr el programa, no en runtime |
| **No requiere un runtime propio separado** | Corre sobre el runtime async que ya tenés (Tokio), sin imponer uno adicional |

> ✅ En criollo: `sqlx` da la seguridad de tipos que buscarías en un ORM, sin esconder el SQL detrás de una capa de abstracción — el mejor punto medio entre control y seguridad para este tipo de proyecto.

---

## 1️⃣6️⃣ Sobre `scripts/init_db.sh`: qué hace y por qué existe 🐳

Ya vimos línea por línea las tres primeras líneas del script (`set -x`, `set -eo pipefail`) en el chat de estudio, pero vale la pena remarcar el **propósito general** del archivo acá:

### El problema que resuelve

Levantar un entorno de desarrollo con base de datos implica varios pasos manuales: levantar un contenedor Docker con Postgres, esperar a que esté listo para aceptar conexiones, crear la base de datos, y correr las migraciones. Hacerlo a mano cada vez es tedioso y propenso a errores (olvidarse un paso, tipear mal un flag).

### Qué automatiza el script

1. **Verifica dependencias** (`psql`, `sqlx`) antes de arrancar, fallando temprano con un mensaje claro si falta algo.
2. **Levanta Postgres en Docker**, con parámetros configurables vía variables de entorno (usuario, password, puerto, nombre de DB), con valores por defecto razonables.
3. **Espera activamente** a que Postgres esté listo — reintentando una conexión de prueba (`psql ... -c '\q'`) en un loop, en vez de asumir un tiempo fijo de espera (que podría ser insuficiente en una máquina lenta, o innecesariamente largo en una rápida).
4. **Crea la base de datos y corre las migraciones**, dejando el entorno listo para trabajar con un solo comando.
5. Permite **saltear el paso de Docker** (`SKIP_DOCKER=true`) para reutilizarse en contextos donde Postgres ya está corriendo por otro medio (por ejemplo, un service container en CI).

> ✅ Es el mismo principio detrás del pipeline de CI: automatizar pasos repetitivos y propensos a error, para que "levantar el entorno" sea un comando reproducible, no una lista de instrucciones que hay que recordar.

---

## 1️⃣7️⃣ Migraciones de base de datos: qué son y por qué versionarlas 🗂️

Una **migración** es un archivo que describe un cambio incremental en la estructura (schema) de la base de datos — crear una tabla, agregar una columna, modificar un tipo de dato.

### La analogía con Git

Así como Git versiona cambios en el código, las migraciones versionan cambios en la **estructura** de la base de datos: cada migración es un paso ordenado cronológicamente, que lleva la base de datos de un estado conocido al siguiente.

### Por qué no alcanza con ejecutar SQL "a mano"

Sin migraciones, no hay forma confiable de saber **qué cambios ya se aplicaron** en cada entorno (tu máquina, la de un compañero, el pipeline de CI, producción). Con migraciones:

- Cada cambio queda en un archivo `.sql`, con nombre único y timestamp.
- La herramienta (`sqlx-cli` en nuestro caso) lleva un registro de qué migraciones ya corrieron contra esa base de datos específica.
- `sqlx migrate run` aplica **solo las pendientes**, en orden, nunca repite una ya aplicada.

### Cómo se usa en este proyecto

- En desarrollo local: `scripts/init_db.sh` corre `sqlx migrate run` como parte del setup.
- En los tests de integración: la función `configure_database` usa `sqlx::migrate!("./migrations")` — la misma lógica, pero invocada directamente desde Rust en vez de un comando de shell, para poder aplicar las migraciones sobre la base de datos temporal y aislada de cada test.

---

## 1️⃣8️⃣ Application State en Actix Web y `app_data` 🗃️

Hasta el capítulo de forms, nuestra aplicación era completamente *stateless* (sin estado): cada handler trabajaba únicamente con los datos del request entrante, sin necesitar nada "compartido" entre requests.

### El problema: los handlers necesitan una conexión a la base de datos

Para persistir un suscriptor, el handler `subscribe` necesita acceso a algo que **no viene en el request** — una conexión (o pool de conexiones) a Postgres. Ese recurso se crea **una vez**, al arrancar la aplicación, y se necesita **compartir** entre todos los requests que lleguen después.

### La solución: `app_data`

Actix Web permite adjuntar datos a la aplicación que no están ligados al ciclo de vida de un único request — el **application state**. Se agrega con el método `.app_data(...)` sobre `App`:

```rust
App::new()
    .app_data(db_pool.clone())
    // ...
```

Cualquier handler puede después "pedir" ese estado como parámetro, usando el extractor `web::Data<T>` (lo vemos en detalle en la sección 20).

---

## 1️⃣9️⃣ Los *workers* de Actix Web: una copia de la app por núcleo 🏭

### El modelo de Actix

Cuando llamás `HttpServer::new(closure)`, **no le estás pasando directamente una `App`** — le pasás un **closure que devuelve** una `App`. Esto es clave para entender por qué existe el problema que resolvemos en la próxima sección.

Actix Web arranca **un worker (proceso/hilo) por cada núcleo disponible en tu máquina**. Cada worker corre **su propia copia** de la aplicación, construida invocando ese mismo closure que le pasaste a `HttpServer::new`.

```rust
HttpServer::new(move || {
    App::new()
        .service(health_check)
        .service(subscribe)
        .app_data(db_pool.clone())
})
```

Este closure se llama **una vez por worker** — si tu máquina tiene 8 núcleos, Actix va a invocarlo 8 veces, generando 8 instancias independientes de `App`, cada una corriendo en su propio worker, procesando requests en paralelo.

### Por qué esto importa para el estado compartido

Como cada worker tiene su **propia copia** de todo lo que hay dentro del closure, cualquier recurso que quieras compartir entre workers (como la conexión a la base de datos) tiene que poder **clonarse** — cada copia de `App` necesita su propia referencia a ese recurso. Esto explica por qué `db_pool.clone()` aparece explícitamente en el código: no es un detalle cosmético, es un requisito estructural del modelo de workers de Actix.

---

## 2️⃣0️⃣ `web::Data`, `Arc`, y el mecanismo de *type-map*: cómo Actix hace "dependency injection" 📌

### El problema con `PgConnection` y `Clone`

Si intentás poner un `PgConnection` directo dentro de `app_data`, el compilador se queja: `HttpServer` exige que todo lo que va dentro del closure sea `Clone` (porque, como vimos, cada worker necesita su propia copia). `PgConnection` **no implementa `Clone`** — tiene sentido, porque por debajo representa un socket TCP real hacia Postgres, y no hay forma sensata de "duplicar" una conexión de red activa.

### La solución: envolver el recurso en `web::Data`

```rust
let db_pool = web::Data::new(db_pool);
```

`web::Data<T>` envuelve tu valor en un **`Arc`** (*Atomic Reference Counted pointer*, un puntero con conteo de referencias atómico). En vez de que cada worker reciba una copia cruda del recurso, cada uno recibe un **puntero** a la misma instancia compartida en memoria.

> ✅ **Dato clave: `Arc<T>` siempre es `Clone`, sin importar si `T` lo es o no.** Clonar un `Arc` no clona el valor de adentro — solo incrementa un contador interno de referencias activas y devuelve una nueva copia de la dirección de memoria. Por eso `db_pool.clone()` funciona perfecto aunque `PgPool`/`PgConnection` no sean clonables por sí mismos.

### Cómo `web::Data<T>` "encuentra" el dato correcto: el *type-map*

Acá está el mecanismo interno, que es genuinamente interesante:

Actix Web representa su estado de aplicación como un **type-map**: un `HashMap` que guarda datos arbitrarios (usando el tipo `Any` de Rust), indexados por su **`TypeId`** — un identificador único que Rust genera para cada tipo distinto en tu programa.

Cuando llega un request y tu handler pide `web::Data<PgPool>` como parámetro:

1. Actix calcula el `TypeId` correspondiente a `PgPool` (el tipo que especificaste en la firma del handler).
2. Busca en el type-map si hay un registro guardado con ese `TypeId` (lo hubo, porque lo registraste con `.app_data(db_pool.clone())`).
3. Si lo encuentra, hace un *downcast* del valor `Any` recuperado de vuelta al tipo concreto (`PgPool`) — seguro, porque el `TypeId` garantiza que no hay ambigüedad de tipos.
4. Se lo entrega a tu handler, ya listo para usar.

### Por qué esto se parece a "dependency injection"

En otros ecosistemas (Java/Spring, C#/.NET), este patrón — pedir una dependencia como parámetro y que el framework te la resuelva automáticamente, sin que vos la construyas a mano dentro del handler — se conoce como **inyección de dependencias**. `web::Data` logra algo funcionalmente equivalente, aunque el mecanismo interno (type-map + `TypeId`) es una solución particular de Rust, aprovechando que el sistema de tipos permite identificar y recuperar valores de forma segura en runtime.

---

## 2️⃣1️⃣ `PgConnection` vs. `PgPool`: repaso con caso de uso real 🔌

Ya vimos la diferencia teórica (sección 15 del capítulo anterior tocaba `Executor`) — acá el repaso aplicado a un caso concreto que resolvimos en este proyecto: `configure_database`, la función que prepara una base de datos nueva para cada test.

| | `PgConnection` | `PgPool` |
|---|---|---|
| Qué es | Una única conexión TCP a Postgres | Un conjunto administrado de conexiones, que se piden y devuelven según demanda |
| ¿Es `Clone`? | No — representa un recurso de sistema único | No directamente, pero se comparte fácilmente envuelto en `web::Data`/`Arc` |
| ¿Soporta queries concurrentes? | No — solo `&mut PgConnection` implementa `Executor`, exclusividad forzada por el compilador | Sí — `&PgPool` implementa `Executor`; el pool presta una conexión libre (o crea/espera una) por cada query |
| Cuándo la usamos en este proyecto | Tarea administrativa puntual: conectarse al servidor (sin apuntar a una DB específica) y ejecutar `CREATE DATABASE` — la base de datos todavía no existe, no hay nada que "poolear" todavía | Todo el resto: correr migraciones, atender requests de la aplicación real, hacer el `SELECT` de verificación en los tests |

> ✅ Regla práctica: `PgConnection` para una operación administrativa aislada y puntual (crear algo que no existe); `PgPool` para cualquier escenario donde la aplicación necesite atender múltiples operaciones concurrentes sobre una base de datos que ya existe.

---

# 📊 Capítulo 4 — Telemetría y Observabilidad

## 2️⃣2️⃣ ¿Por qué instrumentar el código? 🔍

### El problema: "unknown unknowns"

Una vez que una aplicación corre en producción, van a aparecer fallas que **ni siquiera imaginaste al diseñarla** — no vas a estar mirando la pantalla en el momento exacto en que algo se rompa, y muchas veces no es práctico (ni posible) conectar un debugger a un proceso corriendo en un servidor remoto.

La única herramienta real para investigar esos casos después de que ocurrieron es la **telemetría**: información sobre la ejecución de la aplicación, recolectada automáticamente, que se puede inspeccionar más tarde.

### Qué significa "instrumentar"

**Instrumentar** = agregarle al código la capacidad de **reportar qué está haciendo mientras se ejecuta** — el equivalente a ponerle sensores a una máquina, en vez de confiar en que "funciona porque sí".

> 💡 Metáfora: un avión tiene instrumentos (altímetro, velocímetro) que informan constantemente su estado interno. Sin ellos, el piloto solo sabría "vuela o no vuela" — nada sobre *cómo* está volando. Tu código sin instrumentar es igual: sabés que devolvió `200` o `500`, pero no tenés idea de qué pasó en el medio.

Cualquier cosa que reporte información sobre la ejecución cuenta como instrumentación: un span que mide cuánto tardó una operación, o un evento puntual (`tracing::error!`) que registra que algo salió mal.

---

## 2️⃣3️⃣ De `log` a `tracing`: por qué los logs sueltos no alcanzan 🪵

### El problema con logs tradicionales (`log`)

Cada log de la librería `log` es un **evento aislado en el tiempo** — una línea suelta, sin relación con las demás. Con requests concurrentes, los logs de distintos requests se intercalan en la terminal sin ningún orden claro:

```
[INFO] Adding 'thomas@mail.com' as a new subscriber
[INFO] Adding 's_erikson@mail.io' as a new subscriber
[ERROR] Failed to execute query: connection error
```

¿A cuál de los dos suscriptores corresponde el error? Imposible saberlo sin agregar manualmente un identificador a cada log, a mano, en cada función — algo que no escala.

### La solución: el concepto de *span*

A diferencia de un log (un punto en el tiempo), un **span representa una unidad de trabajo con inicio y fin**, que puede contener otros spans anidados adentro. Los datos que le adjuntás a un span (un `request_id`, un email) quedan disponibles automáticamente para todo lo que pase "dentro" de él — no hace falta volver a pasarlos como parámetro en cada función.

---

## 2️⃣4️⃣ ¿Qué es un `Span`, exactamente? ⏱️

Un `Span` es un **struct concreto** (del crate `tracing`) — no es solo una idea abstracta. Cuando escribís `tracing::info_span!(...)` o usás la macro `#[tracing::instrument]`, en algún punto se construye una instancia real de ese tipo.

Cumple **tres funciones combinadas**:

### 1. Cronómetro
Mide cuánto tardó una unidad de trabajo, desde que se creó hasta que se cerró. Es dato duro y medible — en los logs reales del proyecto aparece como el campo `elapsed_milliseconds`.

### 2. Nodo en un árbol de causalidad
Un span puede contener spans hijos, y esa estructura padre-hijo permite reconstruir **qué llamó a qué, y en qué orden**:

```
HTTP REQUEST (200ms total)
  └── Adding a new subscriber (180ms)
        └── Saving new subscriber details in the database (150ms)
```

Con ese árbol, un sistema de observabilidad puede mostrar exactamente qué porción del tiempo total se la comió cada sub-tarea — sin él, solo se conoce el tiempo total, sin saber en qué se fue.

### 3. Contenedor de contexto y eventos
Cualquier dato adjuntado a un span (el `request_id`, el email del suscriptor) queda disponible para sus hijos automáticamente. Y cualquier log emitido mientras el span está activo queda **correlacionado** a él — no flota suelto, sin relación a nada.

> ✅ En conjunto, esto es lo que permite pasar de *"este request tardó 200ms"* a *"y 150 de esos milisegundos fueron específicamente el insert a la base de datos"* — sin esa estructura, solo hay un total, sin visibilidad de dónde se fue el tiempo.

---

## 2️⃣5️⃣ ¿Qué es un `Subscriber`? 🗄️

Los spans y los eventos son solo **cosas que van pasando** — se abre un span, se cierra, ocurre un evento. Algo tiene que **decidir qué hacer con toda esa información**: ¿la descarta? ¿la imprime en la terminal? ¿la manda a un sistema externo?

Eso es exactamente lo que hace un **Subscriber**: recibe y procesa cada uno de esos eventos. Concretamente, es un tipo que se configura una sola vez y se registra como el único encargado de procesar todo, en todo el programa (`init_subscriber`, en este proyecto).

> ⚠️ Si nunca se instala un subscriber, los spans/eventos igual "existen" en tiempo de ejecución, pero nadie los registra en ningún lado — se pierden, como una oficina que genera trámites pero nunca contrató a nadie para archivarlos.

### Cómo se arma en este proyecto (`src/telemetry.rs`)

- **`get_subscriber(name, env_filter, sink)`** — arma la configuración (nombre del servicio, nivel de detalle según `RUST_LOG`, y hacia dónde van los logs: la terminal, o a la nada en tests silenciosos).
- **`init_subscriber(subscriber)`** — lo activa como el subscriber global, una sola vez, al arrancar el programa (o cada test).

### Por qué `static ... LazyLock` en los tests

```rust
static TRACING: LazyLock<()> = LazyLock::new(|| { /* ... */ });
```

Como solo puede haber **un** subscriber activo por programa, y hay muchos tests que llaman a `spawn_app()`, se necesita garantizar que la inicialización ocurra **una sola vez**, sin importar cuántos tests corran. `LazyLock` (parte de `std` desde Rust 1.80, reemplaza a `once_cell::sync::Lazy`) resuelve justo eso: la primera vez que se lo "fuerza" (`LazyLock::force`), ejecuta la inicialización; todas las veces siguientes, la saltea.

---

## 2️⃣6️⃣ Misma infraestructura en desarrollo, test y producción 🏗️

Un punto importante: la instrumentación armada acá (`tracing`, spans, el subscriber) **no es una versión simplificada para practicar** — son los mismos crates y macros que van a correr, tal cual, en un servidor de producción el día del deploy.

### Por qué instrumentar también los tests, no solo la app

> Si no se puede debuggear una falla a partir de los logs durante un test que falla en la propia máquina, va a ser todavía más difícil debuggear ese mismo problema en producción — sin poder reproducirlo a voluntad, y sin poder adjuntar un debugger.

Los tests son el entorno más barato y controlado para confirmar que la instrumentación realmente sirve, antes de que importe de verdad.

### `request_id` consistente de punta a punta

El middleware `TracingLogger` (de `tracing-actix-web`) genera un span raíz con un `request_id` único por cada request HTTP entrante. Mientras el handler no genere su *propio* `request_id` por separado (un error fácil de cometer, señalado explícitamente en el libro), todos los spans/logs de ese request — incluyendo los de sub-funciones como `insert_subscriber` — heredan el mismo ID, permitiendo reconstruir la historia completa de un request específico buscando por ese único identificador.

### Qué cambia al desplegar

Nada de la generación de logs se reescribe. Lo único que cambiaría es el **destino**: en vez de imprimir el JSON en una terminal local, se apuntaría a un servicio de logging remoto (ElasticSearch, o similar) — la instrumentación en sí ya queda resuelta.

---

# 🐳 Capítulo 5 — Going Live: Docker y Despliegue

## 2️⃣7️⃣ Por qué desplegar temprano, no al final 🚀

Es tentador pensar en el despliegue como el último paso, cuando "ya está todo terminado". El libro plantea lo contrario: en desarrollo *trunk-based*, la rama principal debería poder desplegarse en cualquier momento, aunque tenga pocas features.

### Por qué conviene

- **Detecta problemas de infraestructura temprano**, cuando el proyecto es chico y fácil de debuggear — no después de meses de desarrollo, con una arquitectura ya compleja.
- Es la continuación natural del CI: automatizar tests/lint/audit da feedback rápido sobre *"¿el código está bien escrito?"*; desplegar temprano da feedback sobre *"¿esto funciona en un entorno real, no solo en mi máquina?"*.
- A partir de ahí, cada feature nueva se despliega de forma incremental — no hay un "gran deploy final".

---

## 2️⃣8️⃣ Qué es Docker y por qué virtualizar 📦

### El problema: "en mi máquina funciona"

El entorno de desarrollo (tu máquina) y el de producción (un servidor remoto) tienen propósitos distintos, y casi nunca son idénticos: distinta versión de sistema operativo, distintas librerías instaladas, distinta configuración. Un binario compilado en un lugar puede fallar o comportarse distinto en otro.

### La solución: virtualización

En vez de mandar solo el código (o el binario) y confiar en que el entorno remoto tenga todo lo necesario, se empaqueta **el entorno completo** — sistema operativo base incluido — junto con la aplicación. Ese paquete (la **imagen**) corre igual en cualquier lado, porque no depende de nada externo a sí mismo.

> ⚠️ Aclaración importante: la imagen **no incluye el sistema operativo de la máquina donde se construye** — trae su propio SO base (por ejemplo, el de `rust:1`), completamente aislado del de tu máquina. Por eso el mismo contenedor corre igual en tu Ubuntu, en el Windows de un compañero, o en un servidor Linux remoto: ninguno de esos entornos le "presta" su sistema operativo al contenedor.

### El Dockerfile: la receta

Es un archivo de texto con instrucciones, organizadas en **capas**: se parte de una imagen base, y se van ejecutando comandos (`COPY`, `RUN`, etc.) uno detrás de otro para construir el entorno final.

```dockerfile
FROM rust:1          # imagen base, con Rust ya instalado
WORKDIR /app          # directorio de trabajo dentro de la imagen
COPY . .              # copiar el código fuente adentro
ENV SQLX_OFFLINE=true
RUN cargo build --release   # compilar el binario, DENTRO del contenedor
ENTRYPOINT ["./target/release/newsletter-api"]   # qué ejecutar al arrancar
```

---

## 2️⃣9️⃣ Docker expone asunciones implícitas del código 🔍

Un aprendizaje central de este capítulo: los problemas que aparecen al dockerizar la aplicación **no son nuevos** — son asunciones que el código ya tenía, pero que en desarrollo local nunca se notaban porque todo (la app, la base de datos, la terminal) compartía el mismo `localhost`.

| Problema encontrado | Asunción implícita que rompió |
|---|---|
| `sqlx::query!` falla en el build | Asumía que siempre hay una base de datos accesible en tiempo de compilación |
| La app se cuelga esperando conectar a Postgres | Asumía que la base de datos siempre está disponible al arrancar |
| `curl` no puede alcanzar la app | Asumía que "escuchar en `127.0.0.1`" es suficiente para ser alcanzable |

En los tres casos, el código funcionaba perfecto en desarrollo — porque el entorno local disimulaba la asunción. Docker, al aislar todo en redes y sistemas de archivos separados, la vuelve visible.

---

## 3️⃣0️⃣ `SQLX_OFFLINE` en el build de Docker 🗂️

Mismo mecanismo que ya se usa en el pipeline de CI (ver capítulo 4): dentro del contenedor no hay acceso a la base de datos local, así que `sqlx::query!` no puede validarse en tiempo de compilación de la forma habitual. La solución es la misma: usar el caché de metadata de queries (carpeta `.sqlx/`, generada con `cargo sqlx prepare`) en vez de una conexión real, activando `ENV SQLX_OFFLINE=true` en el Dockerfile.

> ✅ Este caché ya estaba resuelto de antes (se generó para el CI) — reutilizarlo acá es la misma solución aplicada a un segundo contexto donde tampoco hay base de datos disponible en build time.

---

## 3️⃣1️⃣ Conexión perezosa: `connect_lazy` y `acquire_timeout` ⏳

### El problema

`PgPoolOptions::connect(...)` intenta conectarse a la base de datos **de inmediato**, de forma bloqueante. Si la base de datos no está disponible en ese momento (como al arrancar un contenedor sin acceso a Postgres), la aplicación **no arranca** — se queda esperando hasta hacer timeout.

### La solución

```rust
let connection_pool = PgPoolOptions::new()
    .acquire_timeout(std::time::Duration::from_secs(2))
    .connect_lazy(configuration.database.connection_string().expose_secret())
    .expect("Failed to create Postgres connection pool.");
```

`connect_lazy` arma el pool **sin conectarse todavía** — recién intenta la conexión real la primera vez que alguien ejecuta una query. Esto permite que el servidor arranque igual, aunque la base de datos no esté disponible en ese instante.

### Por qué además configurar un timeout corto

Sin `acquire_timeout` explícito, el default de `sqlx` es un timeout largo (30 segundos). Preferir un timeout corto (2 segundos) es una decisión de diseño: **fallar rápido y de forma visible** es mejor que quedar colgado en silencio — un principio de resiliencia general, no específico de Rust.

---

## 3️⃣2️⃣ Networking: `127.0.0.1` vs. `0.0.0.0` 🌐

### El problema

Que un puerto esté *mapeado* (`docker run -p 8080:8080`) no alcanza si la aplicación, **dentro** del contenedor, sigue escuchando en `127.0.0.1` — esa dirección significa *"aceptar conexiones solo desde dentro de esta misma máquina/contenedor"*. Un request que llega desde afuera del contenedor (aunque pase por el puerto mapeado) no se considera "local" a esa interfaz, y se descarta antes de llegar siquiera a la aplicación.

### La solución

Bindear a `0.0.0.0` (*"aceptar conexiones desde cualquier interfaz de red"*) — pero **solo en producción/contenedores**. En desarrollo local se prefiere seguir usando `127.0.0.1`, para no exponer el servidor de desarrollo a toda la red local sin querer.

### Cómo se logra sin duplicar código: configuración jerárquica

```
configuration/
├── base.yaml          # valores compartidos entre todos los entornos
├── local.yaml          # host: 127.0.0.1
└── production.yaml     # host: 0.0.0.0
```

Una variable de entorno (`APP_ENVIRONMENT`) determina cuál archivo específico de entorno se combina con el `base.yaml`. El Dockerfile fija `ENV APP_ENVIRONMENT=production`; en desarrollo local, al no estar seteada, se usa `local` por defecto.

> ✅ Este patrón (config base + overrides por entorno + variable que decide cuál cargar) es universal — se repite en prácticamente cualquier stack tecnológico, no es particular de Rust ni de este proyecto.

---

## 3️⃣3️⃣ Multi-stage builds: por qué la imagen final no lleva el compilador 🍳

### El problema del Dockerfile de una sola etapa

Un Dockerfile simple (`FROM rust:1` → `COPY . .` → `RUN cargo build --release`) produce una imagen que incluye **todo lo usado para construir la app**: el compilador de Rust completo, el código fuente, y archivos intermedios de compilación — aunque en runtime solo se necesite un único binario ejecutable. Resultado: imágenes de varios gigabytes, cuando el binario en sí puede pesar unos pocos megabytes.

> 💡 Metáfora: es como servir un plato de comida sin retirar las ollas, cuchillos y el desorden de la cocina donde se preparó — el comensal solo necesita el plato terminado.

### La solución: varias etapas, cada una con un propósito

```dockerfile
FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef   # base con Rust + cargo-chef
FROM chef AS planner                                    # analiza dependencias
FROM chef AS builder                                     # compila dependencias, luego la app
FROM debian:bookworm-slim AS runtime                     # imagen final, mínima
COPY --from=builder /app/target/release/newsletter-api newsletter-api
```

Cada `FROM` arranca un entorno **nuevo e independiente**. `COPY --from=<stage>` permite traer **solo archivos puntuales** de una etapa anterior hacia la siguiente — en este caso, un único binario ya compilado. La etapa final (`runtime`) nunca tuvo el compilador de Rust instalado; parte de una imagen distinta y mínima (`debian:bookworm-slim`), sin arrastrar nada del proceso de construcción.

### `cargo-chef`: cachear la compilación de dependencias por separado

```dockerfile
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json    # analiza SOLO qué dependencias hacen falta

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json   # compila SOLO las dependencias
COPY . .                                                    # recién ahora entra el código propio
RUN cargo build --release --bin newsletter-api
```

Docker cachea capas según si sus **inputs** cambiaron. Al separar "compilar dependencias" (que depende únicamente de `recipe.json`, generado a partir de `Cargo.toml`/`Cargo.lock`) de "compilar el código propio", la capa lenta (compilar ~350 dependencias) queda **cacheada e intacta** mientras no cambien las dependencias — aunque se modifique código de la aplicación en cada build. `builder` arranca desde `chef` (limpio), no desde `planner`, para no arrastrar el código fuente completo antes de necesitarlo, maximizando qué puede quedar cacheado.

### Por qué no hace falta instalar OpenSSL en el runtime

El uso consistente de `rustls` (en vez de TLS nativo del sistema) en todo el proyecto significa que los certificados viajan **embebidos en el propio binario** — la imagen `runtime` final no necesita ningún paquete de sistema relacionado a TLS, a diferencia de un setup con TLS nativo.

---

## 3️⃣4️⃣ De connection strings a `PgConnectOptions`: por qué el tipo de dato importa 🧩

### El problema con un string armado a mano

```rust
format!("postgres://{}:{}@{}:{}/{}", username, password, host, port, db_name)
```

Requiere tener **todos los datos disponibles al mismo tiempo, en el mismo lugar**, para poder concatenarlos con el formato correcto. Funciona mientras todos los valores vengan de una sola fuente (como un archivo `.yaml` local) — pero en producción, los datos de conexión llegan **fragmentados**: algunos desde un archivo (host, puerto — no son secretos), y el password específicamente desde una variable de entorno inyectada por el proveedor cloud en el momento del deploy, nunca escrita en el repo.

### La solución: un objeto estructurado, construido pieza por pieza

```rust
PgConnectOptions::new()
    .host(&self.host)
    .username(&self.username)
    .password(self.password.expose_secret())
    .port(self.port)
    .ssl_mode(ssl_mode)
```

En vez de un string con formato rígido, cada dato de conexión se completa como un campo independiente — permitiendo ensamblar la configuración desde fuentes distintas (archivo + variable de entorno), y agregar opciones adicionales (como el modo SSL) sin arriesgar romper un formato de texto armado a mano.

### `without_db()` vs. `with_db()`

Mismo patrón que ya existía con los strings: una versión de las opciones de conexión **sin** especificar base de datos (necesaria para crear una base de datos que todavía no existe), y otra que agrega el nombre de la base de datos ya elegida:

```rust
pub fn without_db(&self) -> PgConnectOptions { /* host, user, password, puerto, SSL */ }
pub fn with_db(&self) -> PgConnectOptions {
    self.without_db().database(&self.database_name)
}
```

### `PgSslMode`: distinta exigencia según el entorno

```rust
let ssl_mode = if self.require_ssl {
    PgSslMode::Require   // exige conexión encriptada; falla si no es posible
} else {
    PgSslMode::Prefer     // intenta encriptar, pero acepta seguir sin encriptar
};
```

En desarrollo local (`require_ssl: false`), Postgres corriendo en Docker en la misma máquina no suele tener certificados configurados, y el tráfico nunca sale de la máquina — exigir SSL rompería el flujo sin aportar seguridad real. En producción (`require_ssl: true`), el tráfico viaja por red real entre el servidor de la app y la base de datos administrada — ahí sí importa que el canal esté encriptado.

---

## 3️⃣5️⃣ Inyección de variables de entorno estructuradas 🔑

### El problema

Para que `config` pueda tomar valores desde variables de entorno del sistema operativo (no solo desde archivos `.yaml`), necesita una fuente adicional explícita en el builder:

```rust
.add_source(
    config::Environment::with_prefix("APP")
        .prefix_separator("_")
        .separator("__"),
)
```

### Cómo se traduce el nombre de una variable a un campo anidado

```
APP _ DATABASE __ PASSWORD
    ↑              ↑
 prefijo       separador entre niveles anidados
```

`APP_DATABASE__PASSWORD` se mapea automáticamente a `Settings.database.password`. El prefijo (`APP`) evita colisionar con otras variables de entorno del sistema que no tengan nada que ver con la configuración de la aplicación.

### Por qué esta fuente va última en el builder

```rust
config::Config::builder()
    .add_source(config::File::from(base.yaml))
    .add_source(config::File::from(environment.yaml))
    .add_source(config::Environment::with_prefix("APP")...)  // ← última
    .build()?
```

Las fuentes agregadas más tarde tienen **prioridad más alta** — si una variable de entorno existe, sobreescribe lo que digan los archivos `.yaml`. Esto permite que el proveedor cloud inyecte secrets sin necesidad de modificar ningún archivo commiteado al repo.

### El puente entre infraestructura y código: placeholders del proveedor cloud

El `spec.yaml` de DigitalOcean permite referenciar automáticamente las credenciales de una base de datos definida en el mismo spec:

```yaml
envs:
  - key: APP_DATABASE__PASSWORD
    scope: RUN_TIME
    type: SECRET
    value: ${newsletter.PASSWORD}
```

`${newsletter.PASSWORD}` es resuelto por la plataforma en el momento del deploy — nadie necesita ver ni copiar el password real para que llegue correctamente a la variable de entorno `APP_DATABASE__PASSWORD`, que `config` después mapea al struct `Settings`.

---

## 3️⃣6️⃣ Debugging de red en capas: el mismo síntoma, causas distintas 🧅

Un aprendizaje central del deploy real: el mismo síntoma (timeout de conexión) apareció en **tres momentos distintos, con tres causas completamente distintas**. Diagnosticar bien requiere aislar en qué capa está el problema, en vez de asumir la primera explicación.

| Momento | Síntoma | Causa real | Cómo se confirmó |
|---|---|---|---|
| 1 | `PoolTimedOut` en el primer request a producción | Timeout de conexión configurado demasiado corto (2s) para latencia de red real | Se resolvió subiendo el timeout — pero **no era la causa final**, solo destapó la siguiente capa |
| 2 | `relation "subscriptions" does not exist` | Base de datos de producción nunca migrada (solo la local lo estaba) | Mensaje de error explícito, sin ambigüedad |
| 3 | Timeout al intentar migrar desde la máquina local | El firewall/ISP local bloqueaba el puerto no estándar de la base de datos (`25060`) — nada relacionado a credenciales ni configuración de la app | `ufw status verbose` (sin reglas bloqueando salida) + test de conectividad TCP puro (`/dev/tcp/host/puerto`), aislando el problema de cualquier lógica de Postgres/SSL |
| 4 | El mismo timeout, esta vez desde GitHub Actions | El firewall del lado de DigitalOcean ("Trusted Sources") solo permitía la app, no runners externos | Confirmado leyendo la documentación oficial del proveedor sobre el alcance de esa configuración |

### La lección general

> ✅ Un timeout de conexión puede originarse en **cualquier punto de la cadena de red**: configuración de la propia app, el sistema operativo local, el router/ISP, o el firewall del proveedor cloud. Verificar con herramientas que aíslen una sola capa a la vez (`ufw`, un test TCP crudo sin librerías de por medio, la documentación del proveedor) evita atacar la causa equivocada repetidamente.

### Por qué un test de conectividad TCP puro es más confiable que reintentar con la herramienta real

```bash
timeout 10 bash -c "echo > /dev/tcp/<host>/<puerto>" && echo ABIERTO || echo BLOQUEADO
```

Este comando no sabe nada de Postgres, SSL, ni credenciales — solo intenta abrir un socket TCP crudo. Si esto falla, el problema es de **red pura**, ocurre antes de que cualquier protocolo de aplicación (Postgres, HTTP, lo que sea) entre en juego. Aísla la variable de red de todas las demás variables posibles (credenciales mal escritas, configuración de SSL, etc.).

---

## 3️⃣7️⃣ Por qué un frontend nunca choca con estos problemas de red 🖥️

Los bloqueos de red vistos en el capítulo (firewall local hacia el puerto de la base de datos) son específicos de **conexiones administrativas directas** (`psql`, `sqlx migrate`) desde una máquina personal hacia un puerto no estándar. Un frontend (React o cualquier otro) nunca se conecta directamente a la base de datos — le habla a la API (puerto HTTPS estándar, `443`, que ningún ISP bloquea), y es la propia API la que internamente habla con la base de datos, ya con la conectividad de red resuelta del lado del servidor.

```
Frontend → (HTTPS, puerto 443) → API Rust → (dentro de la infraestructura del proveedor) → Base de datos
```

El problema de conectividad restringida solo aparece cuando alguien intenta **saltearse la API** y hablar directo con la base de datos desde fuera de la infraestructura del proveedor cloud.

---

## 3️⃣8️⃣ Costos de infraestructura cloud: facturación por uso, no tarifa fija 💰

Servicios como App Platform y bases de datos administradas de DigitalOcean **no tienen tier gratuito**, pero tampoco cobran una tarifa mensual fija sin importar cuánto se use: la facturación es **por segundo (apps) o por hora (bases de datos)**, con el precio de lista ("$X/mes") representando el máximo si el recurso existe todo el mes.

> ✅ Provisionar, probar, y **destruir** los recursos el mismo día cuesta una fracción del precio de lista — en la práctica, centavos en vez de decenas de dólares.

### La distinción importante: destruir vs. apagar

"Detener"/apagar un recurso (por ejemplo, un droplet apagado pero no eliminado) sigue reservando el espacio, IP, y otros recursos asociados — y sigue facturando. Solo **destruir** (`doctl apps delete`, o el equivalente en el dashboard) detiene la facturación por completo.

---

## ✅ Resumen ejecutivo

| Concepto | Rol |
|---|---|
| **`HttpServer`** | Maneja la capa de transporte (TCP, TLS, conexiones) |
| **`App`** | Builder donde se registra routing, middlewares y handlers |
| **`#[get("/...")]`** | Macro que genera automáticamente `Route` + `Guard`, igual que el `.route()` manual del libro |
| **Extractor (`FromRequest`)** | Resuelve automáticamente los parámetros de un handler (`Path`, `Json`, `Query`, `Data`) |
| **`Future`** | Valor perezoso que necesita ser "poll-eado" para resolverse; cada `async fn` genera una |
| **Tokio (vía `actix_web::rt`)** | El runtime que arranca la macro `#[actix_web::main]` y hace el polling de las futures |
| **`Service`** | Abstracción común a handlers, middlewares y `App`: "recibe un request, devuelve una response async" |
| **Librería + binario** | Separación necesaria para que los tests de integración (`tests/`) puedan importar y ejecutar la lógica real de la app |
| **`.await` secuencial vs. `tokio::spawn`** | Un `.await` bloquea el avance de la task actual; `tokio::spawn` crea una task nueva e independiente, permitiendo concurrencia real |
| **Puerto `0`** | Le pide al sistema operativo que asigne un puerto disponible al azar, evitando colisiones en tests |
| **`rustls`** | Implementación de TLS en Rust puro, sin depender de OpenSSL/`pkg-config` del sistema |
| **`web::Form<T>` / `FromRequest`** | Extractor que parsea y valida un formulario HTML (`x-www-form-urlencoded`) contra un struct, devolviendo `400` automáticamente si faltan campos |
| **Postgres + `sqlx`** | DB relacional por sus garantías de integridad; `sqlx` por ser async nativo, sin ORM, con validación de queries en tiempo de compilación |
| **Migraciones** | Cambios de schema versionados y ordenados, aplicados una sola vez, trackeados por la herramienta (`sqlx-cli` / `sqlx::migrate!`) |
| **Application State / `app_data`** | Mecanismo para compartir recursos (como una conexión a DB) entre todos los handlers, fuera del ciclo de vida de un único request |
| **Workers de Actix** | Un proceso por núcleo de la máquina, cada uno con su propia copia de `App`, construida invocando el mismo closure |
| **`web::Data` + `Arc` + type-map** | Envuelve un recurso no clonable en un `Arc` (siempre clonable); Actix lo recupera vía `TypeId` en un `HashMap` interno — un patrón similar a "dependency injection" |
| **`PgConnection` vs. `PgPool`** | Conexión única para tareas administrativas puntuales (crear una DB); pool para todo lo que requiera concurrencia real |
| **Instrumentar código** | Darle a la aplicación la capacidad de reportar qué está haciendo mientras corre — indispensable para debuggear sin acceso en vivo al proceso |
| **`Span`** | Struct concreto de `tracing`: cronómetro de una unidad de trabajo, nodo en un árbol de causalidad, y contenedor de contexto/eventos correlacionados |
| **`Subscriber`** | Tipo que recibe y procesa spans/eventos (filtra, formatea, decide destino); sin uno registrado, los eventos se pierden |
| **`LazyLock`** | Garantiza que la inicialización del subscriber ocurra una sola vez, sin importar cuántos tests la invoquen |
| **`request_id` vía `TracingLogger`** | Identificador único por request HTTP, heredado por todos los spans/logs internos — permite correlacionar toda la historia de un request puntual |
| **Telemetría dev/test = telemetría en producción** | Los mismos crates y macros instrumentados en desarrollo son los que corren en producción; solo cambia el destino final de los logs |
| **Docker / virtualización** | Empaqueta app + runtime + SO base propio en una imagen reproducible, aislada del entorno donde se construye o ejecuta |
| **Docker expone asunciones implícitas** | Problemas que "no existían" en local (DB no accesible en build, conexión bloqueante, `127.0.0.1`) eran asunciones que el entorno local disimulaba, no bugs nuevos |
| **`SQLX_OFFLINE` + `.sqlx/`** | Permite compilar sin conexión real a la base de datos, tanto en CI como en el build de Docker |
| **`connect_lazy` + `acquire_timeout`** | La app arranca sin bloquear esperando la DB; al fallar, falla rápido y de forma visible en vez de colgarse en silencio |
| **`127.0.0.1` vs `0.0.0.0`** | Escuchar solo en la interfaz local (desarrollo) vs. aceptar conexiones desde cualquier interfaz (contenedores/producción) |
| **Configuración jerárquica por entorno** | Un archivo base + overrides específicos por entorno + una variable que decide cuál cargar — patrón universal, no específico de Rust |
| **Multi-stage builds + `cargo-chef`** | Separa "compilar dependencias" (cacheable, cambia poco) de "compilar código propio" (cambia seguido); la imagen final no lleva el compilador, solo el binario |
| **`PgConnectOptions`** | Configuración de conexión estructurada, ensamblable desde fuentes distintas (archivo + variable de entorno), en vez de un string armado a mano |
| **`config::Environment` con prefijo** | Permite inyectar secrets vía variables de entorno del sistema, mapeadas automáticamente a campos anidados del struct de configuración |
| **Debugging de red en capas** | Un mismo síntoma (timeout) puede originarse en distintas capas (app, SO local, ISP/router, firewall del proveedor) — aislar con herramientas que prueben una sola capa por vez evita atacar la causa equivocada |
| **Facturación cloud por uso** | Apps/bases de datos administradas cobran por segundo/hora de existencia real, no una tarifa fija — destruir (no solo apagar) los recursos detiene el cobro |

---

## 📖 Fuente

Basado en el estudio de *Zero To Production In Rust* (Luca Palmieri), capítulos 3 (Sign Up A New Subscriber), 4 (Telemetry) y 5 (Going Live: Dockerfile, `sqlx` offline, conexión perezosa, networking, configuración jerárquica, multi-stage builds, `PgConnectOptions`, y deploy a DigitalOcean App Platform) completos, contrastado con `cargo expand` sobre el código actual del proyecto usando `actix-web` 4.x, y adaptado a versiones actuales de `sqlx` (0.9, con `acquire_timeout` reemplazando al `connect_timeout` del libro), `config`, `uuid`, `chrono`, `tracing`, `secrecy` (0.10, con `SecretBox`/`SecretString`), y al formato actual del App Spec de DigitalOcean (estructura anidada bajo `services:`, PostgreSQL 16).

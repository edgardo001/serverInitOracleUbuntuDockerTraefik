# Server Init - Oracle Cloud + Docker + Traefik + Apps

> **Estado actual**: HTTPS activo con certificados Let's Encrypt válidos vía DNS-01 (Cloudflare).
> Fecha de última actualización: Junio 2026.

---

## Información del Servidor

| Item | Valor |
|------|-------|
| Proveedor | Oracle Cloud (OCI) |
| SO | Ubuntu 24.04.4 LTS (Noble Numbat) |
| IP Pública | IP_DEL_SERVIDOR |
| IP Privada | 10.0.0.82 |
| Hostname | vnic |
| Usuario SSH | ubuntu |
| Docker | 29.5.2 |
| Docker Compose | plugin v2 (incluido en docker) |
| Kernel | 6.17.0-1011-oracle |

---

## Stack Tecnológico

- **Traefik** v3.7.1 — Proxy reverso con Let's Encrypt (DNS-01 vía Cloudflare)
- **App1** — nginx:alpine → `https://app1.edgardovasquez.cl`
- **App2** — nginx:alpine → `https://app2.edgardovasquez.cl`
- **App X / Y / Z** — Cluster round-robin → `https://app-lb.edgardovasquez.cl`
- **App A / B** — Cluster ponderado (20/80) A/B testing → `https://app-ab.edgardovasquez.cl`
- **Grafana** — Dashboard KPIs → `https://grafana.edgardovasquez.cl` (admin/admin)
- **Prometheus** — Métricas internas (no expuesto públicamente)
- **Dashboard Traefik** — `https://traefik.edgardovasquez.cl` (Basic Auth: credenciales definidas en `traefik/.env`)

---

## Estructura del Proyecto

```
/home/ubuntu/serverInit/
├── README.md                 # Este archivo — guía completa del proyecto
├── traefik/
│   ├── docker-compose.yml    # Contenedor Traefik (proxy reverso)
│   ├── traefik.yml           # Configuración estática de Traefik
│   ├── dynamic.yml           # Configuración dinámica (opciones TLS)
│   ├── .env                  # Variables sensibles (CF token, credenciales)
│   └── data/
│       └── acme.json         # Certificados Let's Encrypt (chmod 600)
├── app1/
│   ├── docker-compose.yml    # Contenedor App1 (nginx)
│   └── index.html            # Página estática de App1
├── app2/
│   ├── docker-compose.yml    # Contenedor App2 (nginx)
│   └── index.html            # Página estática de App2
├── app_x/
│   ├── docker-compose.yml    # Contenedor App X — parte del cluster round-robin
│   └── index.html
├── app_y/
│   ├── docker-compose.yml    # Contenedor App Y — parte del cluster round-robin
│   └── index.html
├── app_z/
│   ├── docker-compose.yml    # Contenedor App Z — parte del cluster round-robin
│   └── index.html
├── app_a/
│   ├── docker-compose.yml    # Contenedor App A — A/B testing (20%)
│   └── index.html
├── app_b/
│   ├── docker-compose.yml    # Contenedor App B — A/B testing (80%)
│   └── index.html
└── monitoring/
    ├── docker-compose.yml    # Prometheus + Grafana
    ├── prometheus/
    │   └── prometheus.yml    # Config de scraping (traefik:8080)
    └── grafana/
        ├── datasources/
        │   └── datasource.yml    # Datasource Prometheus auto-provisionado
        └── dashboards/
            ├── dashboards.yml    # Provisioning de dashboards
            └── traefik-kpi.json  # Dashboard KPIs (A/B, round-robin, latencias)
└── app_b/
    ├── docker-compose.yml    # Contenedor App B — A/B testing (80%)
    └── index.html
```

---

## Guía Paso a Paso (Reproducible)

Esta guía permite recrear el stack completo desde cero en una instancia Oracle Cloud limpia.

---

### Paso 1: Requisitos Previos en Oracle Cloud

#### 1.1 Firewall OCI (Security Lists)

En la consola de Oracle Cloud, debes configurar tu VPS para que permita el acceso a los puertos siguiendo esta ruta:

**Instancias** ➔ **instance-20260530-2112** ➔ **Red** ➔ **Subred** ➔ **seguridad** ➔ **Listas de seguridad** ➔ **Default Security List for vcn-20260530-2116** ➔ **Reglas de seguridad**

Allí debes agregar una regla de **Ingress** (entrada) con los siguientes valores para permitir el tráfico HTTP:

* **Origen**: `0.0.0.0/0`
* **Protocolo IP**: `TCP`
* **Rango de puerto de origen**: `Todo` (o `All` / vacío)
* **Rango de puerto de destino**: `80`

Para el correcto funcionamiento de todo el stack, la tabla completa de reglas de **Ingress** recomendada es:

| Protocolo | Puerto | Origen | Descripción |
|-----------|--------|--------|-------------|
| TCP | 80 | `0.0.0.0/0` | HTTP — necesario para redirección a HTTPS |
| TCP | 443 | `0.0.0.0/0` | HTTPS — tráfico cifrado |
| TCP | 22 | Tu IP pública | SSH — acceso administrativo |

> **Nota**: Sin estas reglas en la consola de OCI, el tráfico externo nunca llegará al servidor, incluso si los puertos están abiertos en el firewall interno (`iptables`).

#### 1.2 Firewall del Sistema Operativo (iptables)

Las imágenes de Ubuntu en Oracle Cloud vienen con reglas de `iptables` preconfiguradas que bloquean tráfico entrante. **Desactivar `ufw` NO es suficiente** porque las reglas están gestionadas por `netfilter-persistent`.

Ejecutar estos comandos por SSH:

```bash
# Abrir puerto 80 (HTTP) — se inserta en la primera posición de la cadena INPUT
sudo iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT

# Abrir puerto 443 (HTTPS) — misma lógica, primera posición
sudo iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT

# Guardar las reglas de forma permanente para que sobrevivan reinicios
sudo netfilter-persistent save
```

**Verificación:**

```bash
sudo iptables -L INPUT -n --line-numbers
```

Deberías ver las reglas `ACCEPT` para los puertos 80 y 443 en las primeras posiciones de la cadena INPUT.

#### 1.3 Cloudflare — API Token

Traefik necesita un token de API de Cloudflare para crear registros TXT temporales que Let's Encrypt usa para validar la propiedad del dominio (challenge DNS-01).

**Pasos para crear el token:**

1. Ir a https://dash.cloudflare.com/profile/api-tokens
2. Clic en **"Create Token"** → seleccionar la plantilla **"Edit zone DNS"**
3. Configurar permisos:
   - **Permissions**: Zone → DNS → Edit
   - **Zone Resources**: Include → Specific zone → `edgardovasquez.cl`
   - **TTL**: dejar por defecto (sin expiración)
4. Clic en **"Continue to summary"** → **"Create Token"**
5. **Copiar el token inmediatamente** — solo se muestra una vez

> **Importante**: Sin este token, Let's Encrypt no puede emitir certificados y las apps no tendrán HTTPS.

#### 1.4 Cloudflare — DNS Records

Crear registros tipo A apuntando a la IP pública del servidor, con proxy naranja activado:

| Tipo | Nombre | Contenido (IP) | Proxy | TTL |
|------|--------|-----------------|-------|-----|
| A | `app1` | `IP_DEL_SERVIDOR` | ✅ Naranja (Proxied) | Auto |
| A | `app2` | `IP_DEL_SERVIDOR` | ✅ Naranja (Proxied) | Auto |
| A | `app-lb` | `IP_DEL_SERVIDOR` | ✅ Naranja (Proxied) | Auto |
| A | `app-ab` | `IP_DEL_SERVIDOR` | ✅ Naranja (Proxied) | Auto |
| A | `grafana` | `IP_DEL_SERVIDOR` | ✅ Naranja (Proxied) | Auto |
| A | `traefik` | `IP_DEL_SERVIDOR` | ✅ Naranja (Proxied) | Auto |

> **Nota**: El proxy naranja oculta la IP real del servidor y habilita la CDN de Cloudflare. Por eso se usa DNS-01 en lugar de HTTP-01 para los certificados.

#### 1.5 Cloudflare — SSL/TLS

En el panel de Cloudflare para el dominio `edgardovasquez.cl`:

1. **SSL/TLS → Overview**: Modo de cifrado → **Full**
   - "Full" significa que Cloudflare se conecta al origen (Traefik) usando HTTPS con certificado Let's Encrypt
2. **SSL/TLS → Edge Certificates**: Habilitar **"Always Use HTTPS"**
   - Esto fuerza la redirección HTTP→HTTPS a nivel de Cloudflare, antes de que llegue al servidor
   - Evita errores `521` que pueden ocurrir cuando Cloudflare intenta conectar al origen en HTTP

---

### Paso 2: Conectarse al Servidor

```bash
ssh ubuntu@IP_DEL_SERVIDOR
```

> Si usas Windows, puedes usar PuTTY o PowerShell con el cliente SSH integrado.

---

### Paso 3: Instalar Docker

```bash
# Descargar e instalar Docker usando el script oficial
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh

# Agregar el usuario actual al grupo docker para no necesitar sudo
sudo usermod -aG docker $USER

# IMPORTANTE: Cerrar sesión y volver a entrar para que el grupo surta efecto
exit
```

Reconectarse:

```bash
ssh ubuntu@IP_DEL_SERVIDOR
```

Verificar:

```bash
docker --version    # Docker version 29.5.2
docker compose version  # Docker Compose version v2.x.x
```

---

### Paso 4: Configurar MTU para Oracle Cloud

Oracle Cloud usa **jumbo frames** (MTU 9000) en su red interna. Docker por defecto crea redes con MTU 1500, lo que causa fragmentación de paquetes y provoca **TLS handshake timeouts** al descargar imágenes de Docker Hub.

**Solución:** Configurar Docker para usar MTU 1450 y DNS públicos:

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "dns": ["1.1.1.1", "8.8.8.8"],
  "mtu": 1450
}
EOF
sudo systemctl restart docker
```

> Sin este ajuste, los `docker pull` fallan con timeout. Es uno de los errores más comunes en Oracle Cloud.

---

### Paso 5: Crear Estructura del Proyecto

```bash
mkdir -p ~/serverInit/traefik/data ~/serverInit/app1 ~/serverInit/app2
```

---

### Paso 6: Crear Red Docker Compartida

Todos los contenedores (Traefik + apps) deben estar en la misma red Docker para que Traefik pueda enrutar el tráfico:

```bash
docker network create traefik-net
```

> Esta red se declara como `external: true` en cada `docker-compose.yml`, lo que significa que Docker Compose no la crea ni la destruye — debe existir previamente.

---

### Paso 7: Crear Archivo acme.json

Este archivo almacena los certificados Let's Encrypt. Debe existir y tener permisos restrictivos (600) antes de iniciar Traefik:

```bash
touch ~/serverInit/traefik/data/acme.json
chmod 600 ~/serverInit/traefik/data/acme.json
```

> **Seguridad**: `acme.json` contiene las claves privadas de los certificados TLS. Nunca subirlo a Git ni compartirlo.

---

### Paso 8: Crear Archivos de Configuración

Todos los archivos de configuración ya existen en el repositorio con comentarios explicativos. A continuación se describe qué hace cada uno y dónde encontrarlo.

| Archivo | Propósito |
|---------|-----------|
| `traefik/.env` | Variables sensibles: token Cloudflare (`CF_DNS_API_TOKEN`), credenciales del dashboard Traefik (`TRAEFIK_PASS_HASH`) y de Grafana (`GRAFANA_ADMIN_USER`/`GRAFANA_ADMIN_PASSWORD`). Ver `traefik/.env.example` para la plantilla. |
| `traefik/traefik.yml` | Configuración **estática** de Traefik (entrypoints, providers, certificador Let's Encrypt). Se lee al iniciar. |
| `traefik/dynamic.yml` | Configuración **dinámica** (TLS + router WRR para A/B testing). Se recarga automáticamente. |
| `traefik/docker-compose.yml` | Contenedor de Traefik con los volumes, puertos, y labels del dashboard. |
| `app1/docker-compose.yml` | App1 expuesta en `app1.edgardovasquez.cl` |
| `app1/index.html` | Página estática de App1 |
| `app2/docker-compose.yml` | App2 expuesta en `app2.edgardovasquez.cl` |
| `app2/index.html` | Página estática de App2 |
| `app_x/docker-compose.yml` | Parte del cluster round-robin (mismo router `app-lb`). Ver nota abajo. |
| `app_x/index.html` | Página de App X |
| `app_y/docker-compose.yml` | Parte del cluster round-robin |
| `app_y/index.html` | Página de App Y |
| `app_z/docker-compose.yml` | Parte del cluster round-robin |
| `app_z/index.html` | Página de App Z |
| `app_a/docker-compose.yml` | App A — A/B testing (20%), solo expone servicio `app-a@docker` |
| `app_a/index.html` | Página de App A |
| `app_b/docker-compose.yml` | App B — A/B testing (80%), solo expone servicio `app-b@docker` |
| `app_b/index.html` | Página de App B |
| `monitoring/docker-compose.yml` | Prometheus + Grafana con auto-provisioning |
| `monitoring/prometheus/prometheus.yml` | Config de scraping hacia Traefik (`traefik:8080/metrics`) |
| `monitoring/grafana/datasources/datasource.yml` | Datasource Prometheus auto-provisionado |
| `monitoring/grafana/dashboards/dashboards.yml` | Provisioning de dashboards |

> **Clave del round-robin**: Los 3 contenedores (`app_x`, `app_y`, `app_z`) usan el **mismo nombre de router** (`app-lb`) y el **mismo nombre de servicio** (`app-lb`). Traefik los agrupa automáticamente como 3 servidores detrás de un solo balanceador. La etiqueta `sticky.cookie=false` deshabilita sesiones persistentes.

> **Arquitectura A/B**: El router `app-ab` y el servicio WRR `app-ab-wrr` se definen en `dynamic.yml`. Los contenedores `app_a` y `app_b` solo exponen sus servicios via labels Docker (`app-a@docker`, `app-b@docker`). Traefik recarga `dynamic.yml` automáticamente — si solo cambias pesos no necesitas reiniciar nada.

### Paso 9: Configurar Token de Cloudflare

Este paso es **crítico**. Sin un token válido, los certificados no se emitirán:

```bash
nano ~/serverInit/traefik/.env
# Cambiar la línea:
#   CF_DNS_API_TOKEN=REEMPLAZA_CON_TU_TOKEN
# Por tu token real:
#   CF_DNS_API_TOKEN=cfut_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

> **Verificar**: El token debe tener permisos Zone:DNS:Edit para `edgardovasquez.cl`.

---

### Paso 10: Iniciar los Servicios

```bash
# Primero Traefik — debe estar listo antes de las apps
# para poder emitir los certificados y configurar el enrutamiento
cd ~/serverInit/traefik && docker compose up -d

# Luego las aplicaciones
cd ~/serverInit/app1 && docker compose up -d
cd ~/serverInit/app2 && docker compose up -d

# Finalmente el cluster round-robin (app_x, app_y, app_z)
cd ~/serverInit/app_x && docker compose up -d
cd ~/serverInit/app_y && docker compose up -d
cd ~/serverInit/app_z && docker compose up -d

# Cluster A/B testing (app_a, app_b)
cd ~/serverInit/app_a && docker compose up -d
cd ~/serverInit/app_b && docker compose up -d

# Finalmente el stack de monitoreo (Prometheus + Grafana)
cd ~/serverInit/monitoring && docker compose up -d
```

> **Nota importante**: Docker en Oracle Cloud es **lento** (30-180 segundos por comando). Esto es normal debido al almacenamiento en bloque con alta latencia de I/O. Ten paciencia y no canceles los comandos prematuramente.

---

### Paso 11: Verificar

#### 11.1 Verificar contenedores activos

```bash
docker ps
```

Deberías ver los 3 contenedores corriendo:

| CONTAINER ID | IMAGE | STATUS | PORTS | NAMES |
|---|---|---|---|---|---|
| ... | traefik:v3.7.1 | Up X minutes | 0.0.0.0:80→80, 0.0.0.0:443→443 | traefik |
| ... | nginx:alpine | Up X minutes | 80/tcp | app1 |
| ... | nginx:alpine | Up X minutes | 80/tcp | app2 |
| ... | nginx:alpine | Up X minutes | 80/tcp | app_x |
| ... | nginx:alpine | Up X minutes | 80/tcp | app_y |
| ... | nginx:alpine | Up X minutes | 80/tcp | app_z |
| ... | nginx:alpine | Up X minutes | 80/tcp | app_a |
| ... | nginx:alpine | Up X minutes | 80/tcp | app_b |
| ... | prom/prometheus:v2.53.0 | Up X minutes | 9090/tcp | prometheus |
| ... | grafana/grafana:11.1.0 | Up X minutes | 3000/tcp | grafana |

#### 11.2 Verificar con curl

```bash
# Verificar que App1 responde con HTTPS (debe retornar HTTP/2 200)
curl -I https://app1.edgardovasquez.cl

# Verificar que App2 responde con HTTPS
curl -I https://app2.edgardovasquez.cl

# Verificar el cluster round-robin — cada petición debe ir a un contenedor distinto
curl -s https://app-lb.edgardovasquez.cl | grep -o '<h1>.*</h1>'
curl -s https://app-lb.edgardovasquez.cl | grep -o '<h1>.*</h1>'
curl -s https://app-lb.edgardovasquez.cl | grep -o '<h1>.*</h1>'
curl -s https://app-lb.edgardovasquez.cl | grep -o '<h1>.*</h1>'
curl -s https://app-lb.edgardovasquez.cl | grep -o '<h1>.*</h1>'
# Deberías ver alternarse: App X, App Y, App Z, App X, App Y...

# Verificar A/B testing — App A (20%) debe aparecer menos que App B (80%)
for i in {1..10}; do curl -s https://app-ab.edgardovasquez.cl | grep -o '<h1>.*</h1>'; done
# Deberías ver ~2 veces App A y ~8 veces App B

# Verificar el dashboard de Traefik con autenticación básica
# Debe retornar código 200
# Reemplaza usuario:contraseña con los valores de traefik/.env
curl -u "usuario:contraseña" -s -o /dev/null -w "%{http_code}" https://traefik.edgardovasquez.cl/dashboard/

# Verificar métricas de Prometheus (debe retornar métricas en texto plano)
curl -s -H "Host: app-ab.edgardovasquez.cl" http://127.0.0.1/metrics 2>/dev/null | head -5 || echo "Prometheus expone en puerto interno 8080"
```

#### 11.3 Verificar desde el navegador

Abrir las siguientes URLs:

- 🟢 https://app1.edgardovasquez.cl — Página "App 1" con gradiente púrpura
- 🟢 https://app2.edgardovasquez.cl — Página "App 2" con gradiente rosa
- 🟢 https://app-lb.edgardovasquez.cl — Cluster round-robin (refrescar para ver alternar entre App X, Y, Z)
- 🟢 https://app-ab.edgardovasquez.cl — A/B testing (App A 20% / App B 80%)
- 🟢 https://grafana.edgardovasquez.cl — Dashboard KPIs (usuario: `admin`, contraseña: `admin`)
- 🟢 https://traefik.edgardovasquez.cl — Dashboard (credenciales definidas en `traefik/.env`)

---

## Notas Importantes

### MTU en Oracle Cloud

Oracle Cloud usa **jumbo frames** (MTU 9000) en su red interna. Docker crea redes con MTU 1500 por defecto, pero los paquetes de 1500 bytes se fragmentan en la red de Oracle y los fragmentos se pierden. Esto causa:
- **TLS handshake timeout** al hacer `docker pull`
- Descargas de imágenes que se quedan colgadas
- Conexiones intermitentes

**Solución**: Configurar MTU 1450 en `/etc/docker/daemon.json` (ver Paso 4).

### Let's Encrypt + Cloudflare (DNS-01)

- Se usa el **challenge DNS-01** porque el proxy naranja de Cloudflare impide que Let's Encrypt acceda directamente al puerto 80 del servidor (que sería necesario para HTTP-01).
- Sin `CF_DNS_API_TOKEN` válido, **no se emiten certificados** y las apps no tendrán HTTPS.
- Los certificados se renuevan **automáticamente cada 90 días** — Traefik lo gestiona sin intervención.
- `acme.json` contiene **claves privadas** de los certificados. **Nunca subir a Git** ni compartir.
- Para respaldar: `cp ~/serverInit/traefik/data/acme.json ~/backup/`

### Redirección HTTP → HTTPS

La redirección ocurre en dos niveles:

1. **Traefik**: Redirige automáticamente peticiones HTTP (puerto 80) a HTTPS (puerto 443) mediante el bloque `http.redirections` en `traefik.yml`.
2. **Cloudflare** (recomendado): Con **"Always Use HTTPS"** activado en SSL/TLS → Edge Certificates, Cloudflare redirige al usuario antes de contactar el servidor. Esto evita errores `521` que pueden ocurrir si Cloudflare intenta conectar al origen en HTTP con SSL/TLS en modo Full.

Verificar la redirección:

```bash
curl -I http://app1.edgardovasquez.cl
# Debe retornar 301 → https://app1.edgardovasquez.cl
```

### Balanceo Round-Robin con Traefik

El cluster `app-lb.edgardovasquez.cl` demuestra una característica poderosa de Traefik: **balanceo de carga automático entre múltiples contenedores**.

**Cómo funciona:**
- Los 3 contenedores (`app_x`, `app_y`, `app_z`) definen el **mismo router** (`app-lb`) y el **mismo servicio** (`app-lb`) en sus labels de Docker.
- Traefik detecta que múltiples contenedores exponen el mismo servicio y los agrupa automáticamente como servidores backend.
- El método de balanceo por defecto es **Weighted Round Robin** (WRR) con peso igual para todos.
- Cada nueva petición HTTP se enruta al siguiente contenedor de la lista circular.

**Verificar el balanceo:**
```bash
# Ejecutar 6 veces seguidas — debe alternar entre App X, Y, Z
for i in {1..6}; do curl -s https://app-lb.edgardovasquez.cl | grep -o '<h1>.*</h1>'; done
```

**Sticky Sessions (opcional):**
Si necesitas que un cliente siempre caiga en el mismo servidor (sesiones persistentes), activa la cookie de afinidad:
```yaml
- "traefik.http.services.app-lb.loadbalancer.sticky.cookie=true"
```
Por defecto está en `false` para forzar el balanceo round-robin puro.

---

### A/B Testing con Weighted Round Robin (WRR)

El cluster `app-ab.edgardovasquez.cl` implementa **A/B testing** distribuyendo tráfico con pesos desiguales:

| App | Peso | Tráfico esperado |
|-----|------|-----------------|
| App A | 20 | ~20% de las peticiones |
| App B | 80 | ~80% de las peticiones |

**Cómo funciona:**
1. Cada contenedor expone su servicio via Docker label: `traefik.http.services.app-a.loadbalancer.server.port=80` (sin router).
2. En `traefik/dynamic.yml` se define el **router** `app-ab` y un servicio **Weighted Round Robin (WRR)** que referencia `app-a@docker` (peso 20) y `app-b@docker` (peso 80).
3. El router enfile apunta al servicio `app-ab-wrr` (mismo archivo, provider file).
4. Traefik recarga `dynamic.yml` automáticamente sin reiniciar.

**Verificar:**
```bash
# 10 peticiones — App A (~20%) debe aparecer ~2 veces
for i in {1..10}; do curl -s https://app-ab.edgardovasquez.cl | grep -o '<h1>.*</h1>'; done
```

**Para cambiar los pesos**, editar `dynamic.yml`:
```yaml
http:
  services:
    app-ab-wrr:
      weighted:
        services:
          - name: app-a@docker
            weight: 30   # ← cambiar aquí
          - name: app-b@docker
            weight: 70   # ← cambiar aquí
```
Traefik detecta el cambio automáticamente (no requiere restart).

---

### Monitoreo con Prometheus + Grafana

El stack de monitoreo permite visualizar en tiempo real los KPIs del balanceo de carga y A/B testing.

**Componentes:**

| Servicio | URL | Credenciales |
|----------|-----|-------------|
| Grafana | `https://grafana.edgardovasquez.cl` | `admin` / `admin` (cambiar en 1er ingreso) |
| Prometheus | Puerto interno 9090 (solo red Docker) | — |

**Dashboard pre-configurado (Traefik KPIs):**

| Panel | Qué muestra |
|-------|------------|
| Distribución A/B Testing | Gráfico de torta con % de requests entre App A (20%) y App B (80%) |
| Distribución Round-Robin | Gráfico de torta con % entre App X, Y, Z (~33% cada una) |
| Requests por Segundo (RPS) | Serie temporal de throughput total |
| % por Servicio A/B | Líneas temporales del porcentaje real vs esperado |
| % por Servicio RR | Líneas temporales del porcentaje real vs esperado |
| Tiempo de Respuesta | P50, P95, P99 en segundos |
| Códigos de Estado HTTP | 2xx, 3xx, 4xx, 5xx por segundo |

**Métricas disponibles** (expuestas por Traefik en `traefik:8080/metrics`):

- `traefik_service_requests_total` — Contador de requests por servicio
- `traefik_service_request_duration_seconds_bucket` — Histograma de latencias
- `traefik_service_request_duration_seconds_sum/count` — Suma y conteo de latencias
- `traefik_entrypoint_requests_total` — Requests por entrypoint

**Comandos útiles:**

```bash
# Verificar que Prometheus recolecta métricas de Traefik
docker exec prometheus wget -qO- http://traefik:8080/metrics | head -20

# Ver targets de Prometheus (UP/DOWN)
curl -s http://127.0.0.1:9090/api/v1/targets | python3 -m json.tool | grep -E '"health"|"job"'

# Hacer consulta rápida a Prometheus (últimos 5 min de requests totales)
curl -s 'http://127.0.0.1:9090/api/v1/query?query=sum(increase(traefik_service_requests_total[5m]))' | python3 -m json.tool
```

> **Nota**: El puerto 9090 de Prometheus NO se expone públicamente. Solo es accesible desde la red Docker. Para consultas ad-hoc usa `docker exec prometheus ...` o accede desde Grafana.

---

### Docker Lento en Oracle Cloud

La instancia Oracle Cloud Free Tier usa almacenamiento en bloque con latencia de I/O relativamente alta. Esto afecta:
- `docker compose up -d` → puede tardar 30-180 segundos
- `docker ps` → puede tardar 5-15 segundos
- `docker pull` → puede tardar varios minutos
- `docker logs` → puede tardar 5-10 segundos en mostrar salida

**No es un error**. Es una característica del almacenamiento de Oracle Cloud Free Tier. Los comandos eventualmente completan — hay que esperar.

---

## Operaciones Comunes

### Agregar una Nueva App

Para agregar, por ejemplo, `app3.edgardovasquez.cl`:

1. **Crear directorio y página HTML**:
   ```bash
   mkdir -p ~/serverInit/app3
   cat > ~/serverInit/app3/index.html << 'EOF'
   <!DOCTYPE html>
   <html lang="es">
   <head><title>App 3</title></head>
   <body><h1>App 3</h1><p>Funcionando con HTTPS</p></body>
   </html>
   EOF
   ```

2. **Crear `docker-compose.yml`** (copiar de app1 y modificar):
   ```bash
   cp ~/serverInit/app1/docker-compose.yml ~/serverInit/app3/docker-compose.yml
   ```
   Editar y cambiar:
   - `container_name: app1` → `container_name: app3`
   - Todas las referencias `app1` en los labels → `app3`
   - `Host(\`app1.edgardovasquez.cl\`)` → `Host(\`app3.edgardovasquez.cl\`)`

3. **Crear registro DNS en Cloudflare**: Tipo A, nombre `app3`, IP `IP_DEL_SERVIDOR`, proxy naranja.

4. **Iniciar el contenedor**:
   ```bash
   cd ~/serverInit/app3 && docker compose up -d
   ```

5. Traefik detecta automáticamente el nuevo contenedor y solicita el certificado a Let's Encrypt.

### Agregar más réplicas al Cluster Round-Robin

Para escalar el cluster `app-lb.edgardovasquez.cl` con más réplicas:

1. **Crear nuevo directorio** (ej. `app_w`):
   ```bash
   mkdir -p ~/serverInit/app_w
   ```

2. **Crear `index.html`** con contenido distintivo.

3. **Crear `docker-compose.yml`**: copiar de `app_x` y cambiar solo `container_name: app_w`. **No cambiar** los labels del router/servicio — deben mantener `app-lb` para que Traefik los agregue al mismo balanceador.

4. **Iniciar**:
   ```bash
   cd ~/serverInit/app_w && docker compose up -d
   ```

5. Traefik detecta automáticamente el nuevo contenedor y comienza a enviarle tráfico en round-robin.

---

### Cambiar Credenciales del Dashboard

```bash
# Generar nuevo hash con la nueva contraseña
openssl passwd -apr1 'NuevaContraseña'
# Salida ejemplo: $apr1$xxxx$yyyyyyyyyyyy

# Editar el archivo .env con el nuevo hash
nano ~/serverInit/traefik/.env
# Cambiar la línea TRAEFIK_PASS_HASH con el nuevo usuario:hash
# NOTA: Duplicar cada $ como $$ (escape de Docker Compose)

# Reiniciar Traefik para aplicar cambios
cd ~/serverInit/traefik && docker compose down && docker compose up -d
```

### Recargar Traefik después de cambios en `dynamic.yml`

| Acción | Comando | Cuándo usarlo |
|--------|---------|---------------|
| **Recarga automática** | *(ninguno)* | Cambios en `dynamic.yml` se detectan solos (ej: cambiar pesos WRR) |
| **Reinicio suave** | `docker compose -f ~/serverInit/traefik/docker-compose.yml restart` | Si la recarga automática no surtió efecto |
| **Reinicio completo** | `cd ~/serverInit/traefik && docker compose down && docker compose up -d` | Cambios en `traefik.yml` (config estática) o en `.env` |

> `docker compose restart` es más rápido que `down + up` porque no recrea el contenedor, solo reinicia el proceso de Traefik.

### Desplegar / Reiniciar / Redeploy apps `app_*`

Todos los comandos funcionan igual para cualquier app (`app_x`, `app_y`, `app_z`, `app_a`, `app_b`, etc.):

```bash
# --- Desplegar por primera vez o después de git pull ---
cd ~/serverInit/app_x && docker compose up -d

# --- Ver estado de una app ---
docker ps --filter name=app_x

# --- Ver logs en tiempo real ---
docker logs app_x -f

# --- Reiniciar una app (sin bajar el contenedor) ---
docker restart app_x

# --- Redeploy (bajar y subir, recarga index.html cambios) ---
cd ~/serverInit/app_x && docker compose down && docker compose up -d

# --- Redeploy forzado (reconstruye sin caché, útil si cambió la imagen) ---
cd ~/serverInit/app_x && docker compose down && docker compose pull && docker compose up -d

# --- Detener app sin eliminar el contenedor ---
docker stop app_x

# --- Iniciar app detenida ---
docker start app_x
```

**Redeploy rápido después de editar `index.html`** (lo más común):
```bash
docker restart app_x   # nginx recarga el archivo del volumen montado
```
Solo `docker compose down && docker compose up -d` forzará a nginx a mostrar cambios en `index.html` porque el volumen `./index.html` se monta como `:ro` (read-only) y nginx cachea en memoria. Si editas `index.html` y no ves cambios, usa `docker restart app_x` primero; si aún no funciona, haz redeploy completo.

**Redeploy de todas las apps `app_*` a la vez:**
```bash
for app in app_x app_y app_z app_a app_b; do (cd ~/serverInit/$app && docker compose down && docker compose up -d); done
```

### Comandos Rápidos

```bash
# Detener todos los servicios (apps primero, luego Traefik)
for d in app1 app2 app_x app_y app_z app_a app_b monitoring traefik; do (cd ~/serverInit/$d && docker compose down); done

# Iniciar todos los servicios, pero con la reconstruccion del contenedor (Traefik primero, luego apps)
for d in traefik app1 app2 app_x app_y app_z app_a app_b monitoring; do (cd ~/serverInit/$d && docker compose up -d --build); done

# Iniciar todos los servicios (Traefik primero, luego apps)
for d in traefik app1 app2 app_x app_y app_z app_a app_b monitoring; do (cd ~/serverInit/$d && docker compose up -d); done

# Ver logs de Traefik en tiempo real
docker logs traefik -f

# Ver últimas 50 líneas de logs de Traefik
docker logs traefik --tail 50

# Reiniciar Traefik sin detener las apps
cd ~/serverInit/traefik && docker compose restart
```

### Comandos de Diagnóstico

```bash
# Ver todos los contenedores (incluso los detenidos)
docker ps -a

# Inspeccionar labels de un contenedor (para verificar configuración de Traefik)
docker inspect app1 --format '{{json .Config.Labels}}'

# Ver logs de Traefik en tiempo real (últimas 50 líneas)
docker logs traefik --tail 50 -f

# Probar enrutamiento local (bypass de DNS y TLS, usando header Host)
curl -I -H "Host: app1.edgardovasquez.cl" http://127.0.0.1
curl -I -H "Host: app2.edgardovasquez.cl" http://127.0.0.1

# Verificar round-robin local (bypass de DNS)
for i in {1..6}; do curl -s -H "Host: app-lb.edgardovasquez.cl" http://127.0.0.1 | grep -o '<h1>.*</h1>'; done

# Verificar A/B testing local
for i in {1..10}; do curl -s -H "Host: app-ab.edgardovasquez.cl" http://127.0.0.1 | grep -o '<h1>.*</h1>'; done

# Probar dashboard con autenticación local
# Reemplaza usuario:contraseña con los valores de traefik/.env
curl -u "usuario:contraseña" -H "Host: traefik.edgardovasquez.cl" http://127.0.0.1/dashboard/

# Verificar resolución DNS desde servidores públicos
dig +short app1.edgardovasquez.cl @1.1.1.1
dig +short app2.edgardovasquez.cl @1.1.1.1
dig +short app-lb.edgardovasquez.cl @1.1.1.1
dig +short app-ab.edgardovasquez.cl @1.1.1.1
dig +short grafana.edgardovasquez.cl @1.1.1.1
dig +short traefik.edgardovasquez.cl @1.1.1.1
```

---

## Solución de Problemas

| Problema | Causa Probable | Solución |
|----------|---------------|----------|
| `404` al visitar una app | App no iniciada o Traefik no la detecta | `docker ps` para verificar contenedores `Up` |
| `502 Bad Gateway` | App iniciada pero no responde internamente | `docker logs app1` para ver errores de nginx |
| Certificados no se emiten | `CF_DNS_API_TOKEN` inválido o no configurado | Verificar `~/serverInit/traefik/.env` y `docker logs traefik` |
| `TLS handshake timeout` al hacer pull | MTU de Docker incorrecto para Oracle Cloud | Verificar que `/etc/docker/daemon.json` tenga `"mtu": 1450` |
| Docker no responde (timeout) | I/O lento del almacenamiento en bloque | Esperar pacientemente y reintentar el comando |
| `521` desde Cloudflare | Cloudflare intenta conectar en HTTP con SSL Full | Habilitar **Always Use HTTPS** en Cloudflare → SSL/TLS → Edge Certificates |
| Dashboard pide credenciales | Comportamiento esperado (Basic Auth) | Ver credenciales en `traefik/.env` |

---

## Historial de Errores Resueltos

Durante la configuración inicial se encontraron y resolvieron los siguientes errores. Se documentan aquí como referencia para futuros despliegues:

| # | Error Identificado | Causa Raíz | Solución Aplicada |
|---|---|---|---|
| 1 | `client version 1.24 is too old. Minimum supported API is 1.40` | Docker Engine v29+ subió la API mínima a `1.40`. Traefik v3.3 usaba la versión `1.24` de la API, incompatible con Docker moderno. | Se actualizó Traefik a **v3.7.1**, que negocia automáticamente la versión de API. |
| 2 | `illegal rune literal` en logs de Traefik | Los contenedores se habían iniciado con comillas simples en las reglas de Host: `Host('app1...')`. Traefik v3 interpreta comillas simples como *runes* de Go. | Se eliminaron contenedores huérfanos y se reconstruyeron con la sintaxis correcta de backticks: `` Host(`app1...`) ``. |
| 3 | `error parsing BasicUser: admin:admin:$apr1$...` | La etiqueta de autenticación duplicaba el prefijo `admin:` antes de la variable `${TRAEFIK_PASS_HASH}`, que ya contenía el usuario y el hash. | Se corrigió la etiqueta en `docker-compose.yml` para usar directamente `${TRAEFIK_PASS_HASH}` sin prefijo adicional. |
| 4 | `failed to find zone... [status code 400] 6003: Invalid request headers` | La variable `CF_DNS_API_TOKEN` tenía el placeholder `REEMPLAZA_CON_TU_TOKEN` en lugar de un token real, impidiendo la validación DNS-01. | Se configuró el token real de Cloudflare en el archivo `.env`. |
| 5 | El dominio `traefik.edgardovasquez.cl` no resolvía | El registro DNS tipo A para `traefik` no existía en Cloudflare (o se escribía incorrectamente como `trafik` sin la **e**). | Se creó/verificó el registro A apuntando a `IP_DEL_SERVIDOR` y se clarificó la ortografía del dominio. |

---

## Modo HTTP de Prueba (Solo Referencia)

> ⚠️ **HISTÓRICO**: Esta sección documenta la configuración de modo HTTP que se usó *temporalmente* durante la depuración inicial. **El estado actual del proyecto es HTTPS** con certificados Let's Encrypt válidos.

Para depuración o pruebas sin un token de Cloudflare válido, el stack puede operar temporalmente en modo HTTP (solo puerto 80, sin TLS):

#### Cambios necesarios para activar modo HTTP:

1. **`traefik/traefik.yml`** — Comentar la redirección HTTP→HTTPS:
   ```yaml
   entryPoints:
     web:
       address: ":80"
       # http:                    # ← Comentar estas 4 líneas
       #   redirections:
       #     entryPoint:
       #       to: websecure
       #       scheme: https
     websecure:
       address: ":443"
   ```

2. **`docker-compose.yml` de cada app y traefik** — Cambiar labels:
   ```yaml
   # Cambiar entrypoint de websecure a web:
   - "traefik.http.routers.<app>.entrypoints=web"        # Era: websecure

   # Comentar las líneas TLS:
   # - "traefik.http.routers.<app>.tls=true"             # ← Comentar
   # - "traefik.http.routers.<app>.tls.certresolver=letsencrypt"  # ← Comentar
   ```

#### Cómo revertir a HTTPS (estado actual):

1. Configurar un token válido de Cloudflare en `traefik/.env`
2. Descomentar el bloque `http.redirections` en `traefik/traefik.yml`
3. En cada `docker-compose.yml`, cambiar `entrypoints` a `websecure` y descomentar las líneas `.tls` y `.tls.certresolver`
4. Reiniciar todos los contenedores:
   ```bash
   for d in traefik app1 app2 app_x app_y app_z app_a app_b monitoring; do (cd ~/serverInit/$d && docker compose down && docker compose up -d); done
   ```

# Server Init - Oracle Cloud + Docker + Traefik + Apps

## Información del Servidor

| Item | Valor |
|------|-------|
| Proveedor | Oracle Cloud (OCI) |
| SO | Ubuntu 24.04.4 LTS (Noble Numbat) |
| IP Pública | IP_DEL_SERVIDOR |
| IP Privada | 10.0.0.82 |
| Hostname | vnic |
| Usuario | ubuntu |
| Docker | 29.5.2 |
| Docker Compose | plugin v2 (incluido en docker) |
| Kernel | 6.17.0-1011-oracle |

## Stack

- **Traefik** v3.7.1 - Proxy reverso con Let's Encrypt (DNS-01 via Cloudflare)
- **App1** - nginx:alpine, sirve en `https://app1.edgardovasquez.cl`
- **App2** - nginx:alpine, sirve en `https://app2.edgardovasquez.cl`
- **Dashboard Traefik** - `https://traefik.edgardovasquez.cl` (auth basic)

---

## Paso a paso (reproducible en otro servidor)

### 1. Requisitos previos

#### 1.1. Oracle Cloud - Firewall (OCI Console)

En la consola de Oracle Cloud:
1. Ir a **Networking → Virtual Cloud Networks** → VCN → Security Lists
2. Asegurar reglas **Ingress** para:
   - Puerto **80** (TCP) desde `0.0.0.0/0`
   - Puerto **443** (TCP) desde `0.0.0.0/0`
   - Puerto **22** (TCP) desde tu IP (SSH)

#### 1.2. Cloudflare - API Token (OBLIGATORIO para SSL)

Traefik necesita un token de Cloudflare para crear registros TXT temporales que Let's Encrypt usa para validar los dominios (DNS-01 challenge).

1. Ir a https://dash.cloudflare.com/profile/api-tokens
2. Botón **"Create Token"** → seleccionar **"Edit zone DNS"**
3. Configurar:
   - **Permissions**: Zone → DNS → Edit
   - **Zone Resources**: Include → Specific zone → `edgardovasquez.cl`
   - **TTL**: dejar por defecto
4. **"Continue to summary"** → **"Create Token"**
5. **Copiar el token inmediatamente** (solo se muestra una vez)

#### 1.3. Cloudflare - DNS Records

Crear registros tipo A con proxy naranja (DNS + Proxy):

| Tipo | Nombre | IP | Proxy |
|------|--------|-----|-------|
| A | `app1` | IP del servidor | ✅ naranja |
| A | `app2` | IP del servidor | ✅ naranja |
| A | `traefik` | IP del servidor | ✅ naranja |

### 2. Conectarse al servidor

```bash
ssh ubuntu@IP_DEL_SERVIDOR
```

### 3. Instalar Docker

```bash
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh
```

Agregar usuario al grupo docker (requiere cerrar sesión y volver a entrar):

```bash
sudo usermod -aG docker $USER
exit  # volver a conectarse
```

### 4. Optimización para Oracle Cloud (MTU)

Oracle Cloud usa MTU 9000 (jumbo frames). Docker necesita MTU menor para evitar timeouts TLS con Docker Hub:

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

### 5. Crear estructura del proyecto

```bash
mkdir -p ~/serverInit/traefik/data ~/serverInit/app1 ~/serverInit/app2
```

### 6. Crear los archivos de configuración

**NO edites archivos manualmente. Usa `nano` o `vim` para pegarlos en los comandos below.**

#### 6.1. Traefik

**`.env`** (`~/serverInit/traefik/.env`):

```bash
cat > ~/serverInit/traefik/.env << 'EOF'
# Cloudflare API Token - REEMPLAZA con tu token real
# Pasos para crear token en cloudflare.com:
# 1. Ir a https://dash.cloudflare.com/profile/api-tokens
# 2. "Create Token" -> "Edit zone DNS"
# 3. Permisos: Zone:DNS:Edit
# 4. Recursos: Include -> Specific zone -> edgardovasquez.cl
# 5. Crear y copiar el token aqui
CF_DNS_API_TOKEN=REEMPLAZA_CON_TU_TOKEN

# Credenciales para el dashboard de Traefik (traefik.edgardovasquez.cl)
# Usuario: admin - Password: edgardovasquez2025
TRAEFIK_PASS_HASH=admin:$$apr1$$DwLjHN2T$$V23FeN8wk2VNkthoeiVNx/
EOF
```

**`traefik.yml`** (`~/serverInit/traefik/traefik.yml`):

```bash
cat > ~/serverInit/traefik/traefik.yml << 'YTRAF'
api:
  dashboard: true

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    filename: /etc/traefik/dynamic.yml

certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@edgardovasquez.cl
      storage: /etc/traefik/acme/acme.json
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"
YTRAF
```

**`dynamic.yml`** (`~/serverInit/traefik/dynamic.yml`):

```bash
cat > ~/serverInit/traefik/dynamic.yml << 'YDYN'
tls:
  options:
    default:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
YDYN
```

**`docker-compose.yml`** (`~/serverInit/traefik/docker-compose.yml`):

```bash
cat > ~/serverInit/traefik/docker-compose.yml << 'YDCF'
services:
  traefik:
    image: traefik:v3.7.1
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - traefik-net
    ports:
      - "80:80"
      - "443:443"
    environment:
      - CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic.yml:/etc/traefik/dynamic.yml:ro
      - ./data/acme.json:/etc/traefik/acme/acme.json
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.rule=Host(`traefik.edgardovasquez.cl`)"
      - "traefik.http.routers.traefik.tls=true"
      - "traefik.http.routers.traefik.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.middlewares=auth"
      - "traefik.http.middlewares.auth.basicauth.users=${TRAEFIK_PASS_HASH?Variable TRAEFIK_PASS_HASH no definida}"

networks:
  traefik-net:
    external: true
YDCF
```

#### 6.2. App1

**`index.html`** (`~/serverInit/app1/index.html`):

```bash
cat > ~/serverInit/app1/index.html << 'YHTML'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>App 1</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            display: flex; justify-content: center; align-items: center;
            min-height: 100vh; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white; text-align: center;
        }
        h1 { font-size: 4rem; margin-bottom: 1rem; }
        p { font-size: 1.2rem; opacity: 0.9; }
    </style>
</head>
<body>
    <div>
        <h1>App 1</h1>
        <p>Servicio 1 funcionando con HTTPS via Traefik</p>
    </div>
</body>
</html>
YHTML
```

**`docker-compose.yml`** (`~/serverInit/app1/docker-compose.yml`):

```bash
cat > ~/serverInit/app1/docker-compose.yml << 'YDC1'
services:
  app1:
    image: nginx:alpine
    container_name: app1
    restart: unless-stopped
    networks:
      - traefik-net
    volumes:
      - ./index.html:/usr/share/nginx/html/index.html:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app1.entrypoints=websecure"
      - "traefik.http.routers.app1.rule=Host(`app1.edgardovasquez.cl`)"
      - "traefik.http.routers.app1.tls=true"
      - "traefik.http.routers.app1.tls.certresolver=letsencrypt"
      - "traefik.http.services.app1.loadbalancer.server.port=80"

networks:
  traefik-net:
    external: true
YDC1
```

#### 6.3. App2

**`index.html`** (`~/serverInit/app2/index.html`):

```bash
cat > ~/serverInit/app2/index.html << 'YHTML2'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>App 2</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            display: flex; justify-content: center; align-items: center;
            min-height: 100vh; background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
            color: white; text-align: center;
        }
        h1 { font-size: 4rem; margin-bottom: 1rem; }
        p { font-size: 1.2rem; opacity: 0.9; }
    </style>
</head>
<body>
    <div>
        <h1>App 2</h1>
        <p>Servicio 2 funcionando con HTTPS via Traefik</p>
    </div>
</body>
</html>
YHTML2
```

**`docker-compose.yml`** (`~/serverInit/app2/docker-compose.yml`):

```bash
cat > ~/serverInit/app2/docker-compose.yml << 'YDC2'
services:
  app2:
    image: nginx:alpine
    container_name: app2
    restart: unless-stopped
    networks:
      - traefik-net
    volumes:
      - ./index.html:/usr/share/nginx/html/index.html:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app2.entrypoints=websecure"
      - "traefik.http.routers.app2.rule=Host(`app2.edgardovasquez.cl`)"
      - "traefik.http.routers.app2.tls=true"
      - "traefik.http.routers.app2.tls.certresolver=letsencrypt"
      - "traefik.http.services.app2.loadbalancer.server.port=80"

networks:
  traefik-net:
    external: true
YDC2
```

### 7. Configurar el token de Cloudflare

**PASO CRÍTICO**: Editar `.env` con el token real:

```bash
nano ~/serverInit/traefik/.env
# Cambiar: CF_DNS_API_TOKEN=REEMPLAZA_CON_TU_TOKEN
# Por:     CF_DNS_API_TOKEN=abc123def456... (el token real)
```

### 8. Crear red compartida y acme.json

```bash
docker network create traefik-net
touch ~/serverInit/traefik/data/acme.json
chmod 600 ~/serverInit/traefik/data/acme.json
```

### 9. Iniciar Traefik

```bash
cd ~/serverInit/traefik
docker compose up -d
```

Este comando puede tardar porque Docker en Oracle Cloud suele ser lento (almacenamiento en bloque). Los timeouts de 60-180s son normales al inicio.

Verificar:

```bash
docker ps
docker logs traefik --tail 20
```

Buscar en los logs: `"Starting provider *docker.Provider"` y luego mensajes de ACME emitiendo certificados.

### 10. Iniciar App1

```bash
cd ~/serverInit/app1
docker compose up -d
```

### 11. Iniciar App2

```bash
cd ~/serverInit/app2
docker compose up -d
```

### 12. Verificar

Revisar contenedores activos:

```bash
docker ps
```

Deberías ver:

| CONTAINER ID | IMAGE | STATUS | NAMES |
|---|---|---|---|
| ... | traefik:v3.7.1 | Up | traefik |
| ... | nginx:alpine | Up | app1 |
| ... | nginx:alpine | Up | app2 |

Probar desde el navegador:

- https://app1.edgardovasquez.cl
- https://app2.edgardovasquez.cl
- https://traefik.edgardovasquez.cl (usuario: `admin`, pass: `edgardovasquez2025`)

O con curl:

```bash
curl -I https://app1.edgardovasquez.cl
curl -I https://app2.edgardovasquez.cl
```

---

## Notas importantes

### MTU en Oracle Cloud
Oracle Cloud usa jumbo frames (MTU 9000). Sin el ajuste `mtu: 1450` en `/etc/docker/daemon.json`, Docker no puede descargar imágenes desde Docker Hub (TLS handshake timeout).

### Let's Encrypt + Cloudflare (DNS-01)
- Se usa DNS-01 challenge porque Cloudflare tiene el proxy naranja activado.
- Sin el `CF_DNS_API_TOKEN`, Let's Encrypt **no puede emitir certificados**.
- Si el token es incorrecto, Traefik reintentará automáticamente.
- Los certificados se almacenan en `traefik/data/acme.json` (chmod 600).

### Certificados
- Expiran a los 90 días. Traefik los renueva automáticamente.
- `acme.json` contiene claves privadas. **No compartir ni subir a git**.
- Para respaldar: `cp ~/serverInit/traefik/data/acme.json ~/backup/`

### Docker lento en Oracle Cloud
Esta instancia Oracle Cloud tiene almacenamiento en bloque con latencia alta. Los comandos Docker (`ps`, `logs`, etc.) pueden tardar 30-180s en responder. **Paciencia**.

### Solución de problemas comunes

| Problema | Causa | Solución |
|----------|-------|----------|
| `404` al visitar app1/app2 | App no iniciada o traefik no la detecta | `docker ps` para verificar apps en ejecución |
| `502 Bad Gateway` | App iniciada pero no responde | `docker logs app1` para ver errores |
| Certificados no se emiten | CF_DNS_API_TOKEN no configurado o inválido | Verificar `.env` y logs de traefik |
| `TLS handshake timeout` al hacer pull | MTU de Docker incorrecto | Verificar `/etc/docker/daemon.json` |
| Docker no responde (timeout) | I/O lento del disco | Esperar y reintentar el comando |

### Agregar una nueva app

1. Crear `~/serverInit/miapp/index.html` con tu contenido
2. Crear `~/serverInit/miapp/docker-compose.yml` (copiar de `app1/docker-compose.yml`)
3. Cambiar en el compose:
   - `container_name`
   - labels: `app1` → `miapp`
   - `Host(\`app1...\`)` → `Host(\`miapp.edgardovasquez.cl\`)`
4. Crear registro DNS en Cloudflare (tipo A, proxy naranja)
5. `cd ~/serverInit/miapp && docker compose up -d`

### Comandos rápidos

```bash
# Detener todo
for d in traefik app1 app2; do (cd ~/serverInit/$d && docker compose down); done

# Iniciar todo
for d in traefik app1 app2; do (cd ~/serverInit/$d && docker compose up -d); done

# Ver logs de Traefik
docker logs traefik -f

# Reiniciar Traefik
docker compose -f ~/serverInit/traefik/docker-compose.yml restart
```

---

### Modo HTTP de Prueba (Sin HTTPS/SSL)

Para propósitos de depuración o pruebas donde no se dispone de un token de Cloudflare válido (o se desea omitir la validación de certificados temporalmente), el stack ha sido configurado para operar **únicamente bajo HTTP (Puerto 80)**.

#### Cambios realizados en la configuración actual:
1. **Traefik (`traefik/traefik.yml`):** Se comentaron las líneas de redirección automática de HTTP a HTTPS:
   ```yaml
   # http:
   #   redirections:
   #     entryPoint:
   #       to: websecure
   #       scheme: https
   ```
2. **Aplicaciones (`app1`, `app2`) y Dashboard (`traefik`):**
   - Se cambió el punto de entrada de `websecure` a `web` en sus respectivos archivos `docker-compose.yml`:
     `"traefik.http.routers.<app>.entrypoints=web"`
   - Se comentaron las líneas de TLS y del resolver de certificados:
     `# "traefik.http.routers.<app>.tls=true"`
     `# "traefik.http.routers.<app>.tls.certresolver=letsencrypt"`

#### Cómo revertir a HTTPS (Producción):
1. Asegúrate de configurar un token válido de Cloudflare en `traefik/.env`.
2. En `traefik/traefik.yml`, descomenta el bloque `http.redirections` de la entrada `web`.
3. En cada `docker-compose.yml` (`traefik`, `app1`, `app2`), vuelve a cambiar `entrypoints` a `websecure` y descomenta las líneas de `.tls` y `.tls.certresolver`.
4. Levanta los contenedores para aplicar cambios:
   ```bash
   for d in traefik app1 app2; do (cd ~/serverInit/$d && docker compose up -d); done
   ```

---

### Registro de Diagnóstico y Comandos Útiles

Durante la resolución de problemas de enrutamiento y acceso (donde se obtenían errores `404` y fallas de carga), se identificaron fallas críticas de configuración y se utilizaron comandos específicos para diagnosticarlas. Este registro sirve como referencia rápida para el futuro.

#### 1. Comandos de Diagnóstico Utilizados

*   **Listar contenedores y estados detallados:**
    ```bash
    docker ps -a
    ```
*   **Inspeccionar etiquetas (labels) de un contenedor específico:**
    *Útil para verificar qué reglas de enrutamiento y middleware ha leído Docker y cómo las ha parseado.*
    ```bash
    docker inspect app1 --format '{{json .Config.Labels}}'
    ```
*   **Ver logs de Traefik en tiempo real o últimas líneas:**
    ```bash
    docker logs traefik --tail 50 -f
    ```
*   **Probar enrutamiento localmente (bypasseando TLS y DNS externo):**
    *Simula una petición externa desde el propio servidor asociando manualmente las cabeceras `Host`.*
    ```bash
    # Para probar la App 1:
    curl -I -H "Host: app1.edgardovasquez.cl" http://127.0.0.1
    # Para probar la App 2:
    curl -I -H "Host: app2.edgardovasquez.cl" http://127.0.0.1
    # Para probar el Dashboard de Traefik (usando Basic Auth):
    curl -u admin:edgardovasquez2025 -H "Host: traefik.edgardovasquez.cl" http://127.0.0.1/dashboard/
    ```
*   **Verificar resolución DNS externa:**
    *Verifica si un host resuelve y a qué IP desde servidores DNS públicos (ej. Cloudflare 1.1.1.1).*
    ```bash
    dig +short traefik.edgardovasquez.cl @1.1.1.1
    ```

#### 2. Historial de Errores y Soluciones Aplicadas

| Error Identificado | Causa Raíz | Solución Aplicada |
| :--- | :--- | :--- |
| **`client version 1.24 is too old... Minimum supported API is 1.40`** (en logs de Traefik) | Docker Engine v29+ subió la versión mínima de la API a `1.40`. Traefik v3.3 venía hardcodeado para solicitar la versión `1.24`, rompiendo la comunicación y causando `404` generalizado. | Se actualizó Traefik a la versión **`v3.7.1`**, la cual negocia automáticamente la versión de la API de Docker. |
| **`illegal rune literal`** (en logs de Traefik) | Los contenedores legacy de `app1` y `app2` se habían iniciado con comillas simples en las reglas: `Host('app1...')`. Traefik v3 interpreta las comillas simples como *runes* de Go y descarta la ruta. | Se eliminaron los contenedores huérfanos y se desplegaron mediante `docker-compose` con la sintaxis correcta de acentos graves (backticks): `Host(\`app1...\`)`. |
| **`error parsing BasicUser: admin:admin:$apr1$...`** | La regla del middleware de autenticación básica duplicaba redundantemente el prefijo de usuario `admin:` antes de la variable `${TRAEFIK_PASS_HASH}` (la cual ya contiene la contraseña y el prefijo de usuario). | Se corrigió la etiqueta en `traefik/docker-compose.yml` para usar directamente la variable `${TRAEFIK_PASS_HASH}`. |
| **`failed to find zone... [status code 400] 6003: Invalid request headers`** | La variable `CF_DNS_API_TOKEN` en el archivo `.env` conservaba el placeholder `REEMPLAZA_CON_TU_TOKEN`, impidiendo a Let's Encrypt verificar la propiedad del dominio. | Se cambió el stack temporalmente a modo HTTP (Puerto 80) para realizar pruebas y se documentó el proceso para restablecerlo a HTTPS. |
| **El dominio `traefik.edgardovasquez.cl` no resolvía** | El registro DNS tipo `A` para el subdominio `traefik` no existía o se estaba escribiendo incorrectamente en el navegador como `trafik` (sin la letra **e**). | Se verificó y corrigió el registro de DNS `A` apuntando a `IP_DEL_SERVIDOR` y se clarificó la ortografía del dominio en el navegador. |

---

## Estructura del proyecto

```
/home/ubuntu/serverInit/
├── README.md
├── traefik/
│   ├── docker-compose.yml
│   ├── traefik.yml
│   ├── dynamic.yml
│   ├── .env
│   └── data/
│       └── acme.json
├── app1/
│   ├── docker-compose.yml
│   └── index.html
└── app2/
    ├── docker-compose.yml
    └── index.html
```

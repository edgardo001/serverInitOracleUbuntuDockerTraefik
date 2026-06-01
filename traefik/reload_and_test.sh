#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Reiniciando Traefik ==="
docker compose down
docker compose up -d

echo "=== Esperando 5 segundos para que los contenedores se estabilicen ==="
sleep 5

echo "=== Verificando variable de entorno dentro del contenedor ==="
docker exec traefik env | grep CF_DNS_API_TOKEN

echo "=== Mostrando últimos logs de ACME (20 líneas) ==="
docker logs --tail 20 traefik | grep -i acme

echo "=== Probando endpoints HTTPS ==="
for d in app1 app2 traefik; do
  echo "--- $d.edgardovasquez.cl ---"
  curl -I -s https://$d.edgardovasquez.cl | head -n 4
 done

echo "=== Listo ==="

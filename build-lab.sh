#!/usr/bin/env bash
set -Eeuo pipefail

# Запускать от имени пользователя dockerroot.
# Не использовать sudo для команд Docker.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CLIENT_NET="lab-client-net"
SERVER_NET="lab-server-net"

CLIENT="lab-client"
FILTER="lab-filter"
SERVER="lab-server"

CLIENT_SUBNET="10.231.10.0/24"
SERVER_SUBNET="10.231.20.0/24"

CLIENT_IP="10.231.10.3"
FILTER_CLIENT_IP="10.231.10.2"
FILTER_SERVER_IP="10.231.20.2"
SERVER_IP="10.231.20.3"

if [[ "${1:-}" == "--reset" ]]; then
    echo "Removing only the resources named by this lab..."
    docker rm -f "$CLIENT" "$FILTER" "$SERVER" 2>/dev/null || true
    docker network rm "$CLIENT_NET" "$SERVER_NET" 2>/dev/null || true
    docker image rm lab-client:local lab-filter:local \
        lab-server:local 2>/dev/null || true
    echo "Reset complete."
    exit 0
fi

if [[ "$(id -un)" != "dockerroot" ]]; then
    echo "ERROR: run as dockerroot, not as root or your normal user."
    echo "Use: sudo machinectl shell dockerroot@"
    exit 1
fi

if ! docker info 2>/dev/null | grep -qi rootless; then
    echo "ERROR: Docker daemon is unavailable or not rootless."
    echo "Check: docker context ls; docker info"
    exit 1
fi

for resource in "$CLIENT" "$FILTER" "$SERVER"; do
    if docker container inspect "$resource" >/dev/null 2>&1; then
        echo "ERROR: container $resource already exists."
        echo "Use ./build-lab.sh --reset to remove this lab first."
        exit 1
    fi
done

for resource in "$CLIENT_NET" "$SERVER_NET"; do
    if docker network inspect "$resource" >/dev/null 2>&1; then
        echo "ERROR: network $resource already exists."
        echo "Inspect it before removing it."
        exit 1
    fi
done

mkdir -p "$ROOT"/{client,filter,server,captures}
chmod 700 "$ROOT/captures"

cat >"$ROOT/client/Dockerfile" <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache iproute2 curl tcpdump python3
CMD ["sleep", "infinity"]
EOF

cat >"$ROOT/filter/Dockerfile" <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache iproute2 tcpdump
CMD ["sleep", "infinity"]
EOF

cat >"$ROOT/server/Dockerfile" <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache iproute2 python3
RUN mkdir -p /srv/www \
    && printf 'Hello from the lab server\n' > /srv/www/index.html
EXPOSE 8080
CMD ["python3", "-m", "http.server", "8080", \
     "--bind", "0.0.0.0", "--directory", "/srv/www"]
EOF

echo "Building images..."
docker build -t lab-client:local "$ROOT/client"
docker build -t lab-filter:local "$ROOT/filter"
docker build -t lab-server:local "$ROOT/server"

echo "Creating isolated networks..."
docker network create \
    --driver bridge --internal \
    --subnet "$CLIENT_SUBNET" "$CLIENT_NET"

docker network create \
    --driver bridge --internal \
    --subnet "$SERVER_SUBNET" "$SERVER_NET"

echo "Starting filter..."
docker run -d \
    --name "$FILTER" \
    --network "$CLIENT_NET" \
    --ip "$FILTER_CLIENT_IP" \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --sysctl net.ipv4.ip_forward=1 \
    --memory 256m --cpus 0.5 --pids-limit 128 \
    --mount "type=bind,src=$ROOT/captures,dst=/captures" \
    lab-filter:local

docker network connect \
    --ip "$FILTER_SERVER_IP" "$SERVER_NET" "$FILTER"

echo "Starting client..."
docker run -d \
    --name "$CLIENT" \
    --network "$CLIENT_NET" \
    --ip "$CLIENT_IP" \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --memory 256m --cpus 0.5 --pids-limit 128 \
    lab-client:local

echo "Starting server..."
docker run -d \
    --name "$SERVER" \
    --network "$SERVER_NET" \
    --ip "$SERVER_IP" \
    --cap-drop ALL \
    --memory 256m --cpus 0.5 --pids-limit 128 \
    lab-server:local

echo "Configuring routes..."
docker exec "$CLIENT" \
    ip route replace "$SERVER_SUBNET" via "$FILTER_CLIENT_IP"

docker exec "$SERVER" \
    ip route replace "$CLIENT_SUBNET" via "$FILTER_SERVER_IP"

echo
echo "Containers:"
docker ps --filter "name=lab-"

echo
echo "Filter interfaces:"
docker exec "$FILTER" ip -br addr

echo
echo "Client routes:"
docker exec "$CLIENT" ip route

echo
echo "Server routes:"
docker exec "$SERVER" ip route

echo
echo "Testing client -> filter -> server..."
docker exec "$CLIENT" \
    curl --fail --connect-timeout 3 \
    "http://$SERVER_IP:8080/"

echo
echo "Initial connectivity test passed."
echo "Capture directory: $ROOT/captures"
echo
echo "This test does NOT prove that bypass paths are impossible."
echo "Verify isolation and packet capture separately."

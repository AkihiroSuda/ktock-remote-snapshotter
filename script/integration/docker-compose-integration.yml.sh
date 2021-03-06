#!/bin/bash

if [ "${1}" == "" ]; then
    echo "Repository path must be provided."
    exit 1
fi

if [ "${2}" == "" ]; then
    echo "Authentication-replated directory path must be provided."
    exit 1
fi

if [ "${3}" == "" ]; then
    echo "Temp dir for /var/lib/rsnapshotd must be provided."
    exit 1
fi

REPO="${1}"
AUTH="${2}"
RS_ROOT_DIR="${3}"

cat <<EOF
version: "3"
services:
  testenv_integration:
    build:
      context: "${REPO}/script/integration/containerd"
      dockerfile: Dockerfile
    container_name: testenv_integration
    privileged: true
    working_dir: /go/src/github.com/ktock/remote-snapshotter
    entrypoint: ./script/integration/containerd/entrypoint.sh
    environment:
    - GO111MODULE=off
    - NO_PROXY=127.0.0.1,localhost,registry_integration:5000
    - HTTP_PROXY=${HTTP_PROXY}
    - HTTPS_PROXY=${HTTPS_PROXY}
    - http_proxy=${http_proxy}
    - https_proxy=${https_proxy}
    tmpfs:
    - /var/lib/containerd
    - /tmp:exec,mode=777
    volumes:
    - "${REPO}:/go/src/github.com/ktock/remote-snapshotter:ro"
    - ${AUTH}:/auth
    - "${RS_ROOT_DIR}:/var/lib/rsnapshotd:rshared"
    - rsstate:/run/rsnapshotd
  registry:
    image: registry:2
    container_name: registry_integration
    environment:
    - HTTP_PROXY=${HTTP_PROXY}
    - HTTPS_PROXY=${HTTPS_PROXY}
    - http_proxy=${http_proxy}
    - https_proxy=${https_proxy}
    - REGISTRY_AUTH=htpasswd
    - REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm"
    - REGISTRY_AUTH_HTPASSWD_PATH=/auth/auth/htpasswd
    - REGISTRY_HTTP_TLS_CERTIFICATE=/auth/certs/domain.crt
    - REGISTRY_HTTP_TLS_KEY=/auth/certs/domain.key
    volumes:
    - ${AUTH}:/auth
  remote_snapshotter_integration:
    build:
      context: "${REPO}/script/integration/rsnapshotd"
      dockerfile: Dockerfile
    container_name: remote_snapshotter_integration
    privileged: true
    working_dir: /go/src/github.com/ktock/remote-snapshotter
    entrypoint: ./script/integration/rsnapshotd/entrypoint.sh
    environment:
    - GO111MODULE=off
    - NO_PROXY=127.0.0.1,localhost,registry_integration:5000
    - HTTP_PROXY=${HTTP_PROXY}
    - HTTPS_PROXY=${HTTPS_PROXY}
    - http_proxy=${http_proxy}
    - https_proxy=${https_proxy}
    tmpfs:
    - /tmp:exec,mode=777
    volumes:
    - "${REPO}:/go/src/github.com/ktock/remote-snapshotter:ro"
    - "${AUTH}:/auth"
    - "${RS_ROOT_DIR}:/var/lib/rsnapshotd:rshared"
    - rsstate:/run/rsnapshotd
    - /dev/fuse:/dev/fuse
volumes:
  rsstate:
EOF

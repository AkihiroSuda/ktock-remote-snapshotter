#!/bin/bash

#   Copyright The containerd Authors.

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

REGISTRY_HOST_INTEGRATION=registry_integration
REGISTRY_HOST_OPTIMIZE=registry-optimize
DUMMYUSER=dummyuser
DUMMYPASS=dummypass
REPO="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/../"

function check {
    if [ ${?} = 0 ] ; then
        echo "Completed: ${1}"
    else
        echo "Failed: ${1}"
        exit 1
    fi
}

function prepare_creds {
    AUTH_DIR="${1}"
    REGISTRY_HOST="${2}"
    USER="${3}"
    PASS="${4}"
    # See also: https://docs.docker.com/registry/deploying/
    mkdir "${AUTH_DIR}/auth" "${AUTH_DIR}/certs"
    check "Preparing temp dir"

    openssl req -subj "/C=JP/ST=Remote/L=Snapshotter/O=TestEnv/OU=Integration/CN=${REGISTRY_HOST}" \
            -newkey rsa:2048 -nodes -keyout "${AUTH_DIR}/certs/domain.key" \
            -x509 -days 365 -out "${AUTH_DIR}/certs/domain.crt"
    check "Preparing self-signed certs"
    
    docker run --entrypoint htpasswd registry:2 -Bbn "${USER}" "${PASS}" > "${AUTH_DIR}/auth/htpasswd"
}

if [ "${1}" == "" ]; then
    echo "No make command provided"
    exit 1
fi

# NOTE: Specify build args via ${DOCKER_BUILD_ARGS}
echo ${DOCKER_BUILD_ARGS}

COMMAND="${1}"

TARGETS=
INTEGRATION=false
OPTIMIZE=false
for T in ${@} ; do
    case "${T}" in
        "integration" ) INTEGRATION=true ;;
        "test-optimize" ) OPTIMIZE=true ;;
        * ) TARGETS="${TARGETS} ${T}" ;;
    esac
done

FAIL=false
if [ "${INTEGRATION}" == "true" ] ; then
    AUTH_DIR=$(mktemp -d)
    prepare_creds "${AUTH_DIR}" "${REGISTRY_HOST_INTEGRATION}" "${DUMMYUSER}" "${DUMMYPASS}"
    check "Preparing creds"
    
    DOCKER_COMPOSE_YAML=$(mktemp)
    RS_ROOT_DIR=$(mktemp -d)
    check "Preparing temp dir for /var/lib/rsnapshotd"

    CONTEXT="${REPO}/script/integration"
    cd "${CONTEXT}"
    "${CONTEXT}"/docker-compose-integration.yml.sh "${REPO}" "${AUTH_DIR}" "${RS_ROOT_DIR}" > "${DOCKER_COMPOSE_YAML}"
    check "Preparing docker-compose.yml"

    if ! ( docker-compose -f "${DOCKER_COMPOSE_YAML}" build ${DOCKER_BUILD_ARGS} testenv_integration remote_snapshotter_integration && \
               docker-compose -f "${DOCKER_COMPOSE_YAML}" up --exit-code-from testenv_integration ) ; then
        FAIL=true
    fi

    echo "Cleaning up environment..."
    docker-compose -f "${DOCKER_COMPOSE_YAML}" down -v
    rm "${DOCKER_COMPOSE_YAML}"
    rm -rf "${AUTH_DIR}"
    rm -rf "${RS_ROOT_DIR}"
fi

if [ "${OPTIMIZE}" == "true" ] ; then
    AUTH_DIR=$(mktemp -d)
    prepare_creds "${AUTH_DIR}" "${REGISTRY_HOST_OPTIMIZE}" "${DUMMYUSER}" "${DUMMYPASS}"
    check "Preparing creds"

    DOCKER_COMPOSE_YAML=$(mktemp)

    CONTEXT="${REPO}/script/optimize"
    cd "${CONTEXT}"
    "${CONTEXT}"/docker-compose-opt.yml.sh "${REPO}" "${AUTH_DIR}" > "${DOCKER_COMPOSE_YAML}"
    check "Preparing docker-compose.yml"

    if ! ( docker-compose -f "${DOCKER_COMPOSE_YAML}" build ${DOCKER_BUILD_ARGS} testenv_opt && \
               docker-compose -f "${DOCKER_COMPOSE_YAML}" up --exit-code-from testenv_opt ) ; then
        FAIL=true
    fi

    echo "Cleaning up environment..."
    docker-compose -f "${DOCKER_COMPOSE_YAML}" down -v
    rm "${DOCKER_COMPOSE_YAML}"
    rm -rf "${AUTH_DIR}"
fi

if [ "$TARGETS" != "" ] ; then
    MINI_CONTEXT=$(mktemp -d)
    cat <<EOF > "${MINI_CONTEXT}/Dockerfile"
FROM golang:1.12
RUN apt-get update -y && apt-get install -y fuse
EOF
    IMAGE_NAME="minienv:$(sha256sum ${MINI_CONTEXT}/Dockerfile | cut -f 1 -d ' ')"
    if ! ( docker build "${MINI_CONTEXT}" -t "${IMAGE_NAME}" ${DOCKER_BUILD_ARGS} && \
               docker run --rm --privileged --device /dev/fuse \
                      --tmpfs /tmp:exec,mode=777 \
                      -w /go/src/github.com/ktock/remote-snapshotter \
                      -v "${REPO}:/go/src/github.com/ktock/remote-snapshotter:ro" \
                      "${IMAGE_NAME}" make $TARGETS PREFIX=/tmp/out/ ) ; then
        FAIL=true
    fi

    echo "Cleaning up environment..."
    rm -r "${MINI_CONTEXT}"
fi

if [ "${FAIL}" == "true" ] ; then
    echo "Some targets failed."
    exit 1
fi

echo "Succeeded all."
exit 0

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

REGISTRY_HOST=registry-optimize
DUMMYUSER=dummyuser
DUMMYPASS=dummypass
ORG_IMAGE_TAG="${REGISTRY_HOST}:5000/test:org$(date '+%M%S')"
OPT_IMAGE_TAG="${REGISTRY_HOST}:5000/test:opt$(date '+%M%S')"

RETRYNUM=100
RETRYINTERVAL=1
TIMEOUTSEC=180
function retry {
    SUCCESS=false
    for i in $(seq ${RETRYNUM}) ; do
        if eval "timeout ${TIMEOUTSEC} ${@}" ; then
            SUCCESS=true
            break
        fi
        echo "Fail(${i}). Retrying..."
        sleep ${RETRYINTERVAL}
    done
    if [ "${SUCCESS}" == "true" ] ; then
        return 0
    else
        return 1
    fi
}

function check {
    if [ ${?} = 0 ] ; then
        echo "Completed: ${1}"
    else
        echo "Failed: ${1}"
        exit 1
    fi
}

function prepare_context {
    CONTEXT_DIR=$(mktemp -d)
    check "Prepare tempdir for context"
    cat <<EOF > "${CONTEXT_DIR}/Dockerfile"
FROM scratch

COPY ./a.txt ./b.txt accessor /
COPY ./c.txt ./d.txt /

ENTRYPOINT ["/accessor"]

EOF
    for SAMPLE in "a" "b" "c" "d" ; do
        echo "${SAMPLE}" > "${CONTEXT_DIR}/${SAMPLE}.txt"
    done
    mkdir -p "${GOPATH}/src/test/test" && \
        cat <<'EOF' > "${GOPATH}/src/test/test/main.go"
package main

import (
	"os"
)

func main() {
	targets := []string{"/a.txt", "/c.txt"}
	for _, t := range targets {
		f, err := os.Open(t)
		if err != nil {
			panic("failed to open file")
		}
		f.Close()
	}
}
EOF
    go build -ldflags '-extldflags "-static"' -o "${CONTEXT_DIR}/accessor" "${GOPATH}/src/test/test"
}

# Connect to the docker server
retry ls /docker/client/cert.pem /docker/client/ca.pem
check "Get certs"
mkdir -p /root/.docker/ && cp /docker/client/* /root/.docker/
retry docker version
check "connect to docker"

# Log into the registry
cp /auth/certs/domain.crt /usr/local/share/ca-certificates
check "Importing cert"
update-ca-certificates
check "Installing cert"
retry docker login "${REGISTRY_HOST}:5000" -u "${DUMMYUSER}" -p "${DUMMYPASS}"
check "Login to the registry"

# Build sample image for testing
prepare_context
check "Prepare context"

# Prepare sample image
tar zcv -C "${CONTEXT_DIR}" . \
    | docker build -t "${ORG_IMAGE_TAG}" - \
    && docker push "${ORG_IMAGE_TAG}"
check "Build and push original image"

# Optimize image
WORKING_DIR=$(mktemp -d)
check "Prepare tempdir for workspace"
GO111MODULE=off PREFIX=/tmp/out/ make clean && \
    GO111MODULE=off PREFIX=/tmp/out/ make ctr-remote && \
    /tmp/out/ctr-remote image optimize -entrypoint='[ "/accessor" ]' "${ORG_IMAGE_TAG}" "${OPT_IMAGE_TAG}"
check "Optimize original image"

# Validate optimized image
docker pull "${OPT_IMAGE_TAG}" && docker save "${OPT_IMAGE_TAG}" | tar xv -C "${WORKING_DIR}"
check "Pull optimized image"

# Model list of files in the optimized layer
BASE_LAYER="${WORKING_DIR}/$(cat "${WORKING_DIR}/manifest.json" | jq -r '.[0].Layers[0]')"
check "Get path of base layer tarball"
UPPER_LAYER="${WORKING_DIR}/$(cat "${WORKING_DIR}/manifest.json" | jq -r '.[0].Layers[1]')"
check "Get path of upper layer tarball"
tar --list -f "${BASE_LAYER}" | tee "${WORKING_DIR}/base-got" && \
    tar --list -f "${UPPER_LAYER}" | tee "${WORKING_DIR}/upper-got"
check "Get list of each layer"
cat <<EOF > "${WORKING_DIR}/base-want"
accessor
a.txt
.prefetch.landmark
b.txt
stargz.index.json
EOF
cat <<EOF > "${WORKING_DIR}/upper-want"
c.txt
.prefetch.landmark
d.txt
stargz.index.json
EOF
diff "${WORKING_DIR}/base-got" "${WORKING_DIR}/base-want"
check "Validate tarball contents of base layer"
diff "${WORKING_DIR}/upper-got" "${WORKING_DIR}/upper-want"
check "Validate tarball contents of upper layer"

exit 0

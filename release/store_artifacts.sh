#!/bin/bash
# Copyright 2017 Istio Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

set -o errexit
set -o nounset
set -o pipefail
set -x

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# This script takes files from a specified directory and uploads
# then to GCR & GCS.  Only tar files in docker/ are uploaded to GCR.

DEFAULT_GCS_PREFIX="istio-testing/builds"
DEFAULT_GCR_PREFIX="istio-testing"

GCS_PREFIX=""
GCR_PREFIX=""

VER_STRING=""
OUTPUT_PATH=""
PUSH_DOCKER="true"
TEST_DOCKER_HUB=""

function usage() {
  echo "$0
    -c <name> Branch of the build                               (required)
    -h <hub>  docker hub to use (optional defaults to gcr.io/istio-testing)
    -i <id>   build ID from cloud builder                       (optional, currently unused)
    -n        disable pushing docker images to GCR              (optional)
    -o <path> src path where build output/artifacts were stored (required)
    -p <name> GCS bucket & prefix path where to store build     (optional, defaults to ${DEFAULT_GCS_PREFIX} )
    -q <name> GCR bucket & prefix path where to store build     (optional, defaults to ${DEFAULT_GCR_PREFIX} )
    -v <ver>  version string for tag & defaulted storage paths"
  exit 1
}

while getopts c:h:no:p:q:v: arg ; do
  case "${arg}" in
    c) BRANCH="${OPTARG}";;
    h) TEST_DOCKER_HUB="${OPTARG}";;
    n) PUSH_DOCKER="false";;
    o) OUTPUT_PATH="${OPTARG}";;
    p) GCS_PREFIX="${OPTARG}";;
    q) GCR_PREFIX="${OPTARG}";;
    v) VER_STRING="${OPTARG}";;
    *) usage;;
  esac
done

[[ -z "${OUTPUT_PATH}" ]] && usage
[[ -z "${VER_STRING}"  ]] && usage
[[ -z "${BRANCH}"      ]] && usage

# remove any trailing / from GCR_PREFIX since docker doesn't like to see //
# do the same for GCS for consistency
GCR_PREFIX=${GCR_PREFIX%/}
GCS_PREFIX=${GCS_PREFIX%/}

GCS_PREFIX=${GCS_PREFIX:-$DEFAULT_GCS_PREFIX}
GCR_PREFIX=${GCR_PREFIX:-$DEFAULT_GCR_PREFIX}

GCS_PATH="gs://${GCS_PREFIX}"
GCR_PATH="gcr.io/${GCR_PREFIX}"
DOCKER_HUB=${TEST_DOCKER_HUB:-$GCR_PATH}

function add_license_to_tar_images() {
for TAR_PATH in "${OUTPUT_PATH}"/docker/*.tar.gz; do
    BASE_NAME=$(basename "$TAR_PATH")
    TAR_NAME="${BASE_NAME%.*}"
    IMAGE_NAME="${TAR_NAME%.*}"

    # if no docker/ directory or directory has no tar files
    if [[ "${IMAGE_NAME}" == "*" ]]; then
      break
    fi
    docker load -i "${TAR_PATH}"
    echo "FROM istio/${IMAGE_NAME}:${VER_STRING}
COPY LICENSES.txt /" > Dockerfile
    docker build -t              "${DOCKER_HUB}/${IMAGE_NAME}:${VER_STRING}" .
    # Include the license text in the tarball as well (overwrite old $TAR_PATH).
    docker save -o "${TAR_PATH}" "${DOCKER_HUB}/${IMAGE_NAME}:${VER_STRING}"
done
}

function docker_tag_images() {
  local DST_HUB
  DST_HUB=$1
  local DST_TAG
  DST_TAG=$2
  local SRC_HUB
  SRC_HUB=$3
  local SRC_TAG
  SRC_TAG=$4

  for TAR_PATH in "${OUTPUT_PATH}"/docker/*.tar.gz; do
    BASE_NAME=$(basename "$TAR_PATH")
    TAR_NAME="${BASE_NAME%.*}"
    IMAGE_NAME="${TAR_NAME%.*}"

    # if no docker/ directory or directory has no tar files
    if [[ "${IMAGE_NAME}" == "*" ]]; then
      break
    fi
    docker load -i "${TAR_PATH}"
    docker tag     "${SRC_HUB}/${IMAGE_NAME}:${SRC_TAG}" \
                   "${DST_HUB}/${IMAGE_NAME}:${DST_TAG}"
    #docker push    "${DST_HUB}/${IMAGE_NAME}:${DST_TAG}"
  done
}

function docker_push_images() {
  local DST_HUB
  DST_HUB=$1
  local DST_TAG
  DST_TAG=$2
  echo "pushing to ${DST_HUB}/image:${DST_TAG}"

  for TAR_PATH in "${OUTPUT_PATH}"/docker/*.tar.gz; do
    BASE_NAME=$(basename "$TAR_PATH")
    TAR_NAME="${BASE_NAME%.*}"
    IMAGE_NAME="${TAR_NAME%.*}"

    # if no docker/ directory or directory has no tar files
    if [[ "${IMAGE_NAME}" == "*" ]]; then
      break
    fi
    docker load -i "${TAR_PATH}"
    docker push    "${DST_HUB}/${IMAGE_NAME}:${DST_TAG}"
  done
}

function add_docker_creds() {
  local PUSH_HUB
  PUSH_HUB=$1

  local ADD_DOCKER_KEY
  ADD_DOCKER_KEY="true"
  if [[ "${ADD_DOCKER_KEY}" != "true" ]]; then
     return
  fi

  if [[ "${PUSH_HUB}" == "docker.io/istio" ]]; then
    echo "using istio cred for docker"
    gsutil -q cp gs://istio-secrets/dockerhub_config.json.enc "$HOME/.docker/config.json.enc"
    gcloud kms decrypt \
       --ciphertext-file="$HOME/.docker/config.json.enc" \
       --plaintext-file="$HOME/.docker/config.json" \
       --location=global \
       --keyring=${KEYRING} \
       --key=${KEY}
    return
  fi

  if [[ "${PUSH_HUB}" == "docker.io/testistio" ]]; then
    gsutil cp gs://istio-secrets/docker.test.json $HOME/.docker/config.json
  fi

  if [[ "${PUSH_HUB}" == gcr.io* ]]; then
    gcloud auth configure-docker -q
  fi
}


if [[ "${PUSH_DOCKER}" == "true" ]]; then
  add_license_to_tar_images

  docker_tag_images  "docker.io/testistio" "${VER_STRING}"          "${DOCKER_HUB}" "${VER_STRING}" 
  docker_tag_images  "docker.io/testistio" "${BRANCH}-latest-daily" "${DOCKER_HUB}" "${VER_STRING}" 
  docker_tag_images  "${GCR_PATH}"         "${BRANCH}-latest-daily" "${DOCKER_HUB}" "${VER_STRING}" 

  add_docker_creds   "${DOCKER_HUB}"
  docker_push_images "${DOCKER_HUB}"       "${VER_STRING}"

  add_docker_creds   "docker.io/testistio"
  docker_push_images "docker.io/testistio" "${VER_STRING}"
  docker_push_images "docker.io/testistio" "${BRANCH}-latest-daily"

  add_docker_creds   "${GCR_PATH}"
  docker_push_images "${GCR_PATH}"         "${BRANCH}-latest-daily"
fi

# preserve the source from the root of the code
pushd "${ROOT}/../../.."
tar -cvzf "${OUTPUT_PATH}/source.tar.gz" .
popd
gsutil -m cp -r "${OUTPUT_PATH}"/* "${GCS_PATH}/"

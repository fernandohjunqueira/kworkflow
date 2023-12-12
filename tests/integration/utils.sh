#!/bin/bash

include './src/lib/kwio.sh'

declare -g CONTAINER_DIR # has the container files to build the container images
declare -g SAMPLES_DIR   # has sample files used accross the integration tests
declare -g KWROOT_DIR    # local kw dir to be copied to and installed in the containers
declare -g DISTROS       # distributions we will run the integration tests

# ensure path to directories is absolute
script_dir=$(realpath "$(dirname "${0}")")
CONTAINER_DIR="${script_dir}/podman"
SAMPLES_DIR="${script_dir}/samples"
KWROOT_DIR=$(realpath "${script_dir}/../..")

# supported distros
DISTROS=('archlinux' 'debian' 'fedora')

# Builds a container image for the given distro
function build_distro_image()
{
  local distro="${1}"
  local file="${CONTAINER_DIR}/Containerfile_${distro}"

  podman image build --file "$file" --tag "kw-${distro}" 2> /dev/null
  
  # Check if the command failed
  if [[ $? -ne 0 ]]; then
    fail "($LINENO): Error building the image for distribution ${distro}"
  fi  
}

# Builds container images and create containers used accross the tests.
function setup_container_environment()
{
  local container_img
  local container_name
  local distro
  local sha_container
  local sha_kw
  local working_directory
  local output # output of podman used to check if containers exist or not

  for distro in "${DISTROS[@]}"; do
    # Only build the image if it does not exists. That's because trying to build
    # the podman image takes a half second even if it exists and is cached.
    podman image exists "kw-${distro}"
    if [[ $? -ne 0 ]]; then
      # Build the image or exit. The integration tests cannot continue otherwise
      build_distro_image "$distro" > /dev/null
      if [[ $? -ne 0 ]]; then
        complain 'failed to setup container environment'
        teardown_container_environment
        exit 1
      fi
    fi

    # the name of the container and the container image.
    container_img="kw-${distro}"
    container_name="kw-${distro}"

    # Get running containers matching the container name.
    # The output of the command will be a list of container names, one per line
    output=$(podman container list --filter name="${container_name}" --format '{{.Names}}')

    # If container is running, we do not recreate it for optimization purposes
    # unless it is outdated.
    if [[ "${output}" == "${container_name}" ]]; then
      # to check if it is outdated, we check kw's version refers to the same
      # commit as this local kw repo.

      # first, get the sha inside the container
      sha_container=$(podman exec "${container_name}" kw --version | grep Commit | sed 's/Commit: //')

      # get the sha of this repo
      sha_kw=$(git --git-dir "${KWROOT_DIR}/.git" rev-parse --short HEAD)

      # if container is up to date, we will reuse it.
      # Otherwise, destroy the container and create a new one.
      if [[ "${sha_kw}" == "${sha_container}" ]]; then
        continue
      else
        teardown_single_container "${container_name}"
      fi
    fi

    # Maybe the container is not running, but it does exist.
    # In this case, we tear it down because it could be in a improper state.
    podman container exists "${container_name}"
    if [[ $? -eq 0 ]]; then
      teardown_single_container "${container_name}"
    fi

    # containers are isolated environments designed to run a  process.  After  the
    # process ends, the container is destroyed. In order execute multiple commands
    # in the container, we need to keep the container,  which  means  the  primary
    # process must not terminate. Therefore, we run a never-ending command as  the
    # primary process,  so  that  we  can  execute  multiple  commands  (secondary
    # processes) and get the output of each of them separately.
    working_directory='/tmp/kw'
    podman run \
      --workdir "${working_directory}" \
      --volume "${KWROOT_DIR}":"${working_directory}" \
      --env PATH='/root/.local/bin:/usr/bin' \
      --name "${container_name}" \
      --detach \
      "${container_img}" sleep infinity > /dev/null

    if [[ $? -ne 0 ]]; then
      fail "($LINENO): Failed to run the container ${container_name}"
    fi  

    # install kw again
    podman exec "${container_name}" \
      ./setup.sh -i --force --skip-docs > /dev/null 2>&1

    if [[ $? -ne 0 ]]; then
      fail "($LINENO): Failed to install kw in the container ${container_name}"
    fi
  done
}

# destroy a single container
function teardown_single_container()
{
  local container="$1"

  podman container exists "${container}"

  if [[ $? -eq 0 ]]; then
    # destroy the container, waiting 0 seconds to send SIGKILL
    podman container rm --force --time 0 "${container}" > /dev/null 2>&1
  fi
}

# destroy all containers used in the tests
teardown_container_environment()
{
  local distro

  for distro in "${DISTROS[@]}"; do
    teardown_single_container "kw-${distro}"
  done
}

# execute a given command in the container
function container_exec()
{
  podman container exec "$@" 2> /dev/null

  if [[ $? -ne 0 ]]; then
    fail "($LINENO): Failed to execute the command in the container."
  fi
}

# copy local file to container
container_copy()
{
  local container="$1"
  local src="$2"
  local dst="$3"
  podman container cp "${src}" "${container}":"${dst}"
}

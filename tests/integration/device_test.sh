#!/bin/bash

include './tests/unit/utils.sh'
include './tests/integration/utils.sh'
include './src/device_info.sh'

function oneTimeSetUp()
{
  setup_container_environment
}

# test if `kw device --local in the container matches the host
function device_info_test_helper()
{
  local distro="${1}"
  local container
  local buffer
  local filter
  local filter_regex
  local output
  local expected_output

  # buffer with all information
  container="kw-${distro}"
  buffer=$(container_exec "$container" kw device --local)

  # some fields must be ignored because they surely won't match
  filter=(
    'Root filesystem' 'Size' 'Mounted on'                        # storage fields
    'Distribution' 'Distribution version' 'Desktop environments' # desktop fields
  )

  # add | separator to each filter item
  filter_regex=$(sed 's/ /|/g' <<< "${filter[@]}")

  # the actual perl regex
  filter_regex="(${filter_regex}):"

  # get the output, after applying filter
  output=$(printf '%s' "${buffer}" | grep --invert-match --perl-regexp "${filter_regex}")

  # get the expected output from the host machine, also filtering information
  expected_output=$(device_main --local | grep --invert-match --perl-regexp "${filter_regex}")

  # deviceinfo shows GPU information for Arch, but not for Debian and Fedora.
  # This is due to some libraries being present in Arch, but not in the others.
  # Therefore, if this information is not present, we must filter it out.
  if ! grep 'GPU:' <<< "${output}" > /dev/null; then
    # we resort to SED because GREP can't filter out lines after context IF we
    # use invert match. First, we tell sed to stop printing lines after matching
    # the pattern GPU then delete the line containing that pattern
    expected_output=$(sed '/GPU:/q' <<< "${expected_output}" | sed '/GPU:/d')
  fi

  # compare
  assertEquals "${output}" "${expected_output}"
}

function test_device_archlinux()
{
  device_info_test_helper 'archlinux'
}

function test_device_debian()
{
  device_info_test_helper 'debian'
}

function test_device_fedora()
{
  device_info_test_helper 'fedora'
}

invoke_shunit

#!/bin/bash

set -euo pipefail

printError() {
  if [ -n "${1}" ]; then
    echo -e "\e[1m\e[31mError: ${1}\e[0m"
  fi
}

printWarn() {
  if [ -n "${1}" ]; then
    echo -e "\e[1m\e[33mWarning: ${1}\e[0m"
  fi
}

printSuccess() {
  if [ -n "${1}" ]; then
    echo -e "\e[1m\e[32m${1}\e[0m"
  fi
}

if [ -z "${1}" ]; then
  printError "No host configured to be processed"
  exit 9
fi

HOST="${1}"
DEPRECATED_TLS="TLSv1.0 TLSv1.1"

echo -e "\e[1mDomain: ${HOST}\e[0m"
HEADERS=$(curl -sI "https://${HOST}")
EXIT_HEADER=$?
TLS=$(nmap --script ssl-enum-ciphers -p443 "${HOST}")
EXIT_TLS=$?
ERROR=0
WARN=0

if [ "${EXIT_HEADER}" -ne 0 ]; then
  ERROR=1
  printError "Fail to retrieve the headers"
fi

if [ "${EXIT_TLS}" -ne 0 ]; then
  ERROR=1
  printError "Fail to retrieve the supported TLS protocol versions"
fi

if echo "${HEADERS}" | grep -qiE "php/[0-9\.]+"; then
  ERROR=1
  printError "PHP version exposed"
fi

if echo "${HEADERS}" | grep -qiE "server:.*[0-9\.]+"; then
  ERROR=1
  printError "Server version exposed"
fi

if echo "${HEADERS}" | grep -qiE "drupal"; then
  ERROR=1
  printError "Drupal CMS exposed"
fi

if ! echo "${HEADERS}" | grep -qi "strict-transport-security"; then
  WARN=1
  printWarn "HSTS not present"
fi

if ! echo "${HEADERS}" | grep -qi "x-frame-options"; then
  WARN=1
  printWarn "X-Frame-Options not present"
fi

if echo "${HEADERS}" | grep -qi "x-powered-by: [^(php)]+"; then
  WARN=1
  printWarn "x-powered-by exposed"
fi

for tls in ${DEPRECATED_TLS}; do
  if echo "${TLS}" | grep -qiE "${tls}"; then
    ERROR=1
    printError "${tls} protocol is deprecated"
  fi
done

if [ "${ERROR}" -eq 0 ] && [ "${WARN}" -eq 0 ]; then
  printSuccess "All the security checks are ok"
fi

if [ "${ERROR}" -ne 0 ]; then
  exit 2
fi

if [ "${WARN}" -ne 0 ]; then
  exit 1
fi

exit 0

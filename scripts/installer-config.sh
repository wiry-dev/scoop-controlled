#!/bin/bash
# Shared settings for update-installers.sh and migrate-installers.sh, which mirror installers into an artifact
# repository (e.g. Nexus) and point manifests at the mirrored copies.
#
# Every setting can be given, in order of precedence, as:
#   1. a command-line option of the same name:  --REPO_URL=https://repo.example.org  or  --REPO_URL https://...
#   2. an environment variable of the same name: REPO_URL=https://repo.example.org ./scripts/update-installers.sh
#   3. otherwise the placeholder default below, which will not work until replaced.
#
# Settings:
#   REPO_URL               Base URL of the artifact repository
#   REPO_ID                Repository id to upload to (also the Maven server id)
#   REPO_GROUP_ID          Maven group id used for uploaded installers
#   REPO_UPLOAD_URL        Upload (deploy) URL            [default: $REPO_URL/content/repositories/$REPO_ID]
#   REPO_DOWNLOAD_URL      Base URL manifests download from [default: $REPO_URL/repository/$REPO_ID]
#   REPO_MIRROR_URL        Maven mirror URL               [default: $REPO_URL/repository/mirror]
#   REPO_USERNAME          Upload account
#   REPO_PASSWORD          Upload password
#   REPO_PASSWORD_COMMAND  Command printing the password, used when REPO_PASSWORD isn't given (e.g. "pass show repo/uploader")
#   MAVEN_SETTINGS_TEMPLATE  Maven settings template      [default: files/settings.xml]

INSTALLER_SETTINGS=(REPO_URL REPO_ID REPO_GROUP_ID REPO_UPLOAD_URL REPO_DOWNLOAD_URL REPO_MIRROR_URL REPO_USERNAME REPO_PASSWORD REPO_PASSWORD_COMMAND MAVEN_SETTINGS_TEMPLATE)
PLACEHOLDER_PASSWORD="CHANGE_ME_REPO_PASSWORD"

# Applies --NAME=value / --NAME value options for known settings; anything else is an error.
parse_installer_options() {
  while [ $# -gt 0 ]; do
    local ARG="${1}" NAME VALUE
    case "${ARG}" in
      --*=*) NAME="${ARG%%=*}"; NAME="${NAME#--}"; VALUE="${ARG#*=}"; shift ;;
      --*)   NAME="${ARG#--}"; VALUE="${2}"; shift; [ $# -gt 0 ] && shift ;;
      *)     echo "[ERROR] Unexpected argument '${ARG}'"; exit 1 ;;
    esac
    if [[ " ${INSTALLER_SETTINGS[*]} " != *" ${NAME} "* ]]; then
      echo "[ERROR] Unknown option '--${NAME}'. Known: ${INSTALLER_SETTINGS[*]}"
      exit 1
    fi
    printf -v "${NAME}" '%s' "${VALUE}"
  done
}

# Fills in defaults for anything not set, then exports everything so child scripts see the same values.
apply_installer_defaults() {
  : "${REPO_URL:=https://repo.example.com}"
  : "${REPO_ID:=thirdparty}"
  : "${REPO_GROUP_ID:=scoop}"
  : "${REPO_UPLOAD_URL:=${REPO_URL}/content/repositories/${REPO_ID}}"
  : "${REPO_DOWNLOAD_URL:=${REPO_URL}/repository/${REPO_ID}}"
  : "${REPO_MIRROR_URL:=${REPO_URL}/repository/mirror}"
  : "${REPO_USERNAME:=uploader}"
  : "${MAVEN_SETTINGS_TEMPLATE:=files/settings.xml}"
  if [ -z "${REPO_PASSWORD}" ]; then
    if [ -n "${REPO_PASSWORD_COMMAND}" ]; then
      REPO_PASSWORD="$(eval "${REPO_PASSWORD_COMMAND}")" || { echo "[ERROR] REPO_PASSWORD_COMMAND failed"; exit 1; }
    else
      REPO_PASSWORD="${PLACEHOLDER_PASSWORD}"
    fi
  fi
  export "${INSTALLER_SETTINGS[@]}"

  if [[ "${REPO_URL}" == *example.com* || "${REPO_PASSWORD}" == "${PLACEHOLDER_PASSWORD}" ]]; then
    echo "[WARN] Placeholder repository settings in use (REPO_URL=${REPO_URL}); set REPO_URL, REPO_USERNAME and REPO_PASSWORD (or REPO_PASSWORD_COMMAND)"
  fi
}

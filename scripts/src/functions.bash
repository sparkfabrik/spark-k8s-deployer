#!/usr/bin/env bash

# This file contains only functions.
# Nothing should be executed nor defined here.
# Including this file in a script will make all functions available
# but will not change the environment.

print-banner() {
  if [ -n "${1:-}" ]; then
    echo "----- ${1} -----"
  fi
}

print_job_info() {
  print-banner "JOB INFO"
  local PAD_LEN VAR_NAME
  PAD_LEN=${PAD_LEN:-40}
  for VAR_NAME in "HOSTNAME" "CI_JOB_NAME" "CI_JOB_NAME_SLUG" \
    "CI_COMMIT_AUTHOR" "CI_RUNNER_EXECUTABLE_ARCH" \
    "CI_RUNNER_DESCRIPTION"; do
    printf "%-${PAD_LEN}s \e[1m%s\e[0m\n" "${VAR_NAME}:" "${!VAR_NAME}"
  done

  print-banner "END JOB INFO"
}

print_debug_sleep_help() {
  print-banner "DEBUG SLEEP HELP"
  echo "If DEBUG_JOB_SLEEP is 1 and CI_JOB_NAME_SLUG matches DEBUG_JOB_SLEEP_JOB_NAME, the job will sleep for the specified duration."
  echo "To activate it, you can set the variables as follows:"
  echo "DEBUG_JOB_SLEEP=1 DEBUG_JOB_SLEEP_JOB_NAME=${CI_JOB_NAME_SLUG} DEBUG_JOB_SLEEP_DURATION=3600"
  print-banner "END DEBUG SLEEP HELP"
}

create_kubeconfig() {
  print-banner "CREATING KUBECONFIG"
  KUBECONFIG="$(pwd)/kubeconfig"
  export KUBECONFIG
  export KUBE_CLUSTER_OPTIONS=
  if [[ -n "$KUBE_CA_PEM" ]]; then
    echo "Using KUBE_CA_PEM..."
    echo "$KUBE_CA_PEM" >"$(pwd)/kube.ca.pem"
    KUBE_CLUSTER_OPTIONS=--certificate-authority="$(pwd)/kube.ca.pem"
    export KUBE_CLUSTER_OPTIONS
  fi
  kubectl config set-cluster gitlab-deploy --server="$KUBE_URL" \
    "$KUBE_CLUSTER_OPTIONS"
  kubectl config set-credentials gitlab-deploy --token="$KUBE_TOKEN" \
    "$KUBE_CLUSTER_OPTIONS"
  kubectl config set-context gitlab-deploy \
    --cluster=gitlab-deploy --user=gitlab-deploy \
    --namespace="$KUBE_NAMESPACE"
  kubectl config use-context gitlab-deploy
  print-banner "END CREATING KUBECONFIG"
}

ensure_deploy_variables() {
  if [[ -z "$KUBE_URL" ]]; then
    echo "Missing KUBE_URL."
    exit 1
  fi

  if [[ -z "$KUBE_TOKEN" ]]; then
    echo "Missing KUBE_TOKEN."
    exit 1
  fi

  if [[ -z "$KUBE_NAMESPACE" ]]; then
    echo "Missing KUBE_NAMESPACE."
    exit 1
  fi

  if [[ -z "$CI_ENVIRONMENT_SLUG" ]]; then
    echo "Missing CI_ENVIRONMENT_SLUG."
    exit 1
  fi

  if [[ -z "$CI_ENVIRONMENT_URL" ]]; then
    echo "Missing CI_ENVIRONMENT_URL."
    exit 1
  fi
}

ping_kube() {
  if kubectl version >/dev/null; then
    echo "Kubernetes is online!"
    echo ""
  else
    echo "Cannot connect to Kubernetes."
    return 1
  fi
}

prepare-namespace() {
  if [ -z "${KUBE_NAMESPACE}" ]; then
    echo "KUBE_NAMESPACE is missing."
    exit 1
  fi
  echo "Namespace \"$KUBE_NAMESPACE\" already exists."
  if ! kubectl get ns "$KUBE_NAMESPACE" >/dev/null 2>&1; then
    if ! kubectl create ns "$KUBE_NAMESPACE"; then
      echo "Failed to create namespace $KUBE_NAMESPACE"
      exit 1
    fi
  else
    echo "Namespace $KUBE_NAMESPACE already exists."
  fi
}

create-ns-and-developer-role-bindings() {
  prepare-namespace
  if [ -z "${CI_COMMIT_REF_SLUG}" ]; then
    echo "CI_COMMIT_REF_SLUG is missing."
    exit 1
  fi
  ALLOWED_PATTERN=${ALLOWED_PATTERN_OVERRIDE:-'^(dev|develop|(review-.*))$'}
  if ! [[ ${CI_COMMIT_REF_SLUG} =~ $ALLOWED_PATTERN ]]; then
    echo "Not in Dev/Review branch: not handling team access via RBAC"
    echo "Used pattern is: ${ALLOWED_PATTERN}"
    return 0
  fi
  if [ -z "${CI_PROJECT_ID}" ]; then
    echo "CI_PROJECT_ID is missing."
    exit 1
  fi
  VIEWER_RB=$(PROJECT_ROLE=viewer envsubst <"$DEPLOY_ROOT_DIR/templates/rbac/rolebinding.yaml")
  DEVELOPER_RB=$(PROJECT_ROLE=developer envsubst <"$DEPLOY_ROOT_DIR/templates/rbac/rolebinding.yaml")
  IFS=',' read -r -a VIEWER_U <<<"${DEV_VIEWER_USERS}"
  IFS=',' read -r -a VIEWER_G <<<"${DEV_VIEWER_GROUPS}"
  IFS=',' read -r -a DEVELOPER_U <<<"${DEV_DEVELOPER_USERS}"
  IFS=',' read -r -a DEVELOPER_G <<<"${DEV_DEVELOPER_GROUPS}"
  for SUBJECT in "${VIEWER_U[@]}"; do
    VIEWER_RB+=$'\n'$(SUBJECT_TYPE=User SUBJECT_NAME=${SUBJECT} envsubst <"$DEPLOY_ROOT_DIR/templates/rbac/rolebinding-subject.yaml")
  done
  for SUBJECT in "${VIEWER_G[@]}"; do
    VIEWER_RB+=$'\n'$(SUBJECT_TYPE="Group" SUBJECT_NAME="${SUBJECT}" envsubst <"$DEPLOY_ROOT_DIR/templates/rbac/rolebinding-subject.yaml")
  done
  for SUBJECT in "${DEVELOPER_U[@]}"; do
    DEVELOPER_RB+=$'\n'$(SUBJECT_TYPE=User SUBJECT_NAME=${SUBJECT} envsubst <"$DEPLOY_ROOT_DIR/templates/rbac/rolebinding-subject.yaml")
  done
  for SUBJECT in "${DEVELOPER_G[@]}"; do
    DEVELOPER_RB+=$'\n'$(SUBJECT_TYPE="Group" SUBJECT_NAME="${SUBJECT}" envsubst <"$DEPLOY_ROOT_DIR/templates/rbac/rolebinding-subject.yaml")
  done
  echo "$VIEWER_RB"
  echo "$VIEWER_RB" | kubectl apply -f -
  echo "$DEVELOPER_RB"
  echo "$DEVELOPER_RB" | kubectl apply -f -
}

helm-init() {
  print-banner "HELM INIT"
  helm version
  helm repo add "stable" "https://charts.helm.sh/stable"
  helm repo add "sparkfabrik" "${SPARKFABRIK_CHART_REPO_URL:-https://storage.googleapis.com/spark-helm-charts}"
  helm repo update
  print-banner "HELM INIT"
}

_gitlab-agent-print-vars() {
  local PAD_LEN VAR_NAME
  PAD_LEN=${PAD_LEN:-40}
  printf "\e[1mConfigured Gitlab Agent related variables in order of precedence:\e[0m\n"
  for VAR_NAME in "KUBE_NAMESPACE" "DISABLE_GITLAB_AGENT" \
    "GITLAB_AGENT_PROJECT" "GITLAB_AGENT_ID" \
    "DEVELOP_GITLAB_AGENT_PROJECT" "DEVELOP_GITLAB_AGENT_ID" \
    "PRODUCTION_GITLAB_AGENT_PROJECT" "PRODUCTION_GITLAB_AGENT_ID" \
    "NON_DEVELOP_BRANCHES_REGEX"; do
    printf "%-${PAD_LEN}s \e[1m%s\e[0m\n" "${VAR_NAME}:" "${!VAR_NAME}"
  done
}

_gitlab-agent-print-workflow() {
  # Flow description:
  # 1. GITLAB_AGENT_PROJECT and GITLAB_AGENT_ID (no branch dependency)
  # 2. BRANCH = NON_DEVELOP_BRANCHES_REGEX ? DEVELOP_GITLAB_AGENT_PROJECT and DEVELOP_GITLAB_AGENT_ID : PRODUCTION_GITLAB_AGENT_PROJECT and PRODUCTION_GITLAB_AGENT_ID

  if [ "${DISABLE_GITLAB_AGENT:-0}" = "1" ]; then
    echo "The deployment will not use the GitLab Agent because it is disabled by using the DISABLE_GITLAB_AGENT environment variable."
  elif [ -n "${GITLAB_AGENT_PROJECT:-}" ] && [ -n "${GITLAB_AGENT_ID:-}" ]; then
    echo "You have configured a specific GitLab Agent project and ID. It will be used for the deployment."
  elif echo "${CI_COMMIT_REF_SLUG}" | grep -qvE "^(${NON_DEVELOP_BRANCHES_REGEX})$"; then
    echo "Your branch '${CI_COMMIT_REF_SLUG}' does not match the '${NON_DEVELOP_BRANCHES_REGEX}' regex, it means that we handle it as a development branch."
    echo "The DEVELOP_GITLAB_AGENT_PROJECT and DEVELOP_GITLAB_AGENT_ID variables will be used, if they are present."
  elif echo "${CI_COMMIT_REF_SLUG}" | grep -qE "^(${NON_DEVELOP_BRANCHES_REGEX})$"; then
    echo "Your branch '${CI_COMMIT_REF_SLUG}' matches the '${NON_DEVELOP_BRANCHES_REGEX}' regex, it means that we handle it as a production branch."
    echo "The PRODUCTION_GITLAB_AGENT_PROJECT and PRODUCTION_GITLAB_AGENT_ID variables will be used, if present."
  elif [ "${CI_SERVER_VERSION_MAJOR}" -ge "17" ]; then
    echo "The GitLab Agent is not configured correctly. Please check the variables and the workflow."
  else
    echo "The GitLab Agent is not configured. We use the environment based cluster configuration."
  fi
}

_setup-gitlab-agent-kubernetes-context() {
  if [ "${1:-}" = "" ]; then
    echo "Missing the GitLab Agent host project name."
    exit 1
  fi
  if [ "${2:-}" = "" ]; then
    echo "Missing the GitLab Agent ID."
    exit 1
  fi

  echo "Switching Kubernetes context to use the context provided by the GitLab Agent."
  echo "The used GitLab Agent ID is: ${2}"

  kubectl config use-context "${1}:${2}"

  echo "Setting the namespace to: ${KUBE_NAMESPACE:-default}"
  kubectl config set-context --current --namespace="${KUBE_NAMESPACE:-default}"
}

setup-gitlab-agent() {
  print-banner "SETUP GITLAB AGENT"
  _gitlab-agent-print-vars
  _gitlab-agent-print-workflow
  print-banner "END SETUP GITLAB AGENT"

  # If the GitLab Agent is disabled, return early.
  if [ "${DISABLE_GITLAB_AGENT:-0}" = "1" ]; then
    return
  fi

  # If the GitLab Agent variables are configured to a specific project and ID, use them.
  if [ -n "${GITLAB_AGENT_PROJECT:-}" ] && [ -n "${GITLAB_AGENT_ID:-}" ]; then
    _setup-gitlab-agent-kubernetes-context "${GITLAB_AGENT_PROJECT}" "${GITLAB_AGENT_ID}"
    return
  fi

  # If the current branch is non-production and the development variables are set, use the develop GitLab Agent.
  # Please note the `-v` in the grep command that is used to invert the match.
  if echo "${CI_COMMIT_REF_SLUG}" | grep -qvE "^(${NON_DEVELOP_BRANCHES_REGEX})$"; then
    if [ -z "${DEVELOP_GITLAB_AGENT_PROJECT:-}" ] || [ -z "${DEVELOP_GITLAB_AGENT_ID:-}" ]; then
      return
    fi

    _setup-gitlab-agent-kubernetes-context "${DEVELOP_GITLAB_AGENT_PROJECT}" "${DEVELOP_GITLAB_AGENT_ID}"
    return
  fi

  # If the current branch is a production ones and the production variables are set, use the production GitLab Agent.
  if echo "${CI_COMMIT_REF_SLUG}" | grep -qE "^(${NON_DEVELOP_BRANCHES_REGEX})$"; then
    if [ -z "${PRODUCTION_GITLAB_AGENT_PROJECT:-}" ] || [ -z "${PRODUCTION_GITLAB_AGENT_ID:-}" ]; then
      return
    fi

    _setup-gitlab-agent-kubernetes-context "${PRODUCTION_GITLAB_AGENT_PROJECT}" "${PRODUCTION_GITLAB_AGENT_ID}"
    return
  fi
}

#!/usr/bin/env bash

# This file contains only functions.
# Nothing should be executed nor defined here.
# Including this file in a script will make all functions available
# but will not change the environment.

create_kubeconfig() {
  echo "Generating kubeconfig..."
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
  echo ""
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
  echo "Current KUBE_NAMESPACE=${KUBE_NAMESPACE}"
  kubectl create ns "$KUBE_NAMESPACE" || true
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
  helm version
  helm repo add "stable" "https://charts.helm.sh/stable"
  helm repo add "sparkfabrik" "${SPARKFABRIK_CHART_REPO_URL:-https://storage.googleapis.com/spark-helm-charts}"
  helm repo update
}

setup-gitlab-agent() {
  if [ -n "${GITLAB_AGENT_PROJECT:-}" ] && [ -n "${GITLAB_AGENT_ID:-}" ] && [ "${DISABLE_GITLAB_AGENT:-0}" != "1" ]; then
    echo "The deployment will use the GitLab Agent."
    echo "Switching Kubernetes context to use the context provided by the GitLab Agent."
    kubectl config use-context "${GITLAB_AGENT_PROJECT}:${GITLAB_AGENT_ID}"
  fi
}

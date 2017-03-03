set -eo pipefail

[[ "$TRACE" ]] && set -x

export CI_CONTAINER_NAME="ci_job_build_$CI_BUILD_ID"
export CI_REGISTRY_TAG="$CI_BUILD_REF_NAME"

create_kubeconfig() {
  echo "Generating kubeconfig..."
  export KUBECONFIG="$(pwd)/kubeconfig"
  export KUBE_CLUSTER_OPTIONS=
  if [[ -n "$KUBE_CA_PEM" ]]; then
    echo "Using KUBE_CA_PEM..."
    echo "$KUBE_CA_PEM" > "$(pwd)/kube.ca.pem"
    export KUBE_CLUSTER_OPTIONS=--certificate-authority="$(pwd)/kube.ca.pem"
  fi
  kubectl config set-cluster gitlab-deploy --server="$KUBE_URL" \
    $KUBE_CLUSTER_OPTIONS
  kubectl config set-credentials gitlab-deploy --token="$KUBE_TOKEN" \
    $KUBE_CLUSTER_OPTIONS
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
  if kubectl version > /dev/null; then
    echo "Kubernetes is online!"
    echo ""
  else
    echo "Cannot connect to Kubernetes."
    return 1
  fi
}

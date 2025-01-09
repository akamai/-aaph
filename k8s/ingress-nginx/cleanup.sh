#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -o pipefail  # Pipeline will return the exit status of the last command to exit with a non-zero status

function log_section {
    echo "---------------------------------------------------------------------------"
    echo "$1"
    echo "---------------------------------------------------------------------------"
}

uninstall_helm_release_in_namespace() {
  local namespace=$1
  releases=$(helm list -n "$namespace" -q)

  if [ -z "$releases" ]; then
    echo "No Helm releases found in the '$namespace' namespace."
  else
    echo "Found Helm release in the '$releases' namespace: $namespace"

    for release in $releases; do
      echo "Uninstalling Helm release: $release"
      helm uninstall "$release" -n "$namespace"

      if [ $? -eq 0 ]; then
        echo "Successfully uninstalled Helm release: $release"
      else
        echo "Failed to uninstall Helm release: $release"
      fi
    done
  fi
}

uninstall_configmap_in_namespace() {
  local namespace=$1
  local configmap_name=$2

  configmap_exists=$(kubectl get configmap "$configmap_name" -n "$namespace" --ignore-not-found)

  if [ -z "$configmap_exists" ]; then
    echo "No ConfigMap named '$configmap_name' found in the '$namespace' namespace."
  else
    echo "Found ConfigMap '$configmap_name' in the '$namespace' namespace."

    echo "Uninstalling ConfigMap: $configmap_name"
    kubectl delete configmap "$configmap_name" -n "$namespace"

    if [ $? -eq 0 ]; then
      echo "Successfully deleted ConfigMap: $configmap_name"
    else
      echo "Failed to delete ConfigMap: $configmap_name"
    fi
  fi
}

uninstall_secret_in_namespace() {
  local namespace=$1
  local secret_name=$2

  secret_exists=$(kubectl get secret "$secret_name" -n "$namespace" --ignore-not-found)

  if [ -z "$secret_exists" ]; then
    echo "No Secret named '$secret_name' found in the '$namespace' namespace."
  else
    echo "Found Secret '$secret_name' in the '$namespace' namespace."

    # Uninstall the Secret
    echo "Uninstalling Secret: $secret_name"
    kubectl delete secret "$secret_name" -n "$namespace"

    if [ $? -eq 0 ]; then
      echo "Successfully deleted Secret: $secret_name"
    else
      echo "Failed to delete Secret: $secret_name"
    fi
  fi
}


function main() {
  local ingress_namespace="ingress-nginx"
  local origin_namespace="origin"

  log_section "Uninstalling ingress controller"
  uninstall_helm_release_in_namespace  $ingress_namespace

  log_section "Uninstalling origin"
  uninstall_helm_release_in_namespace  $origin_namespace

  log_section "Uninstalling nginx origin"
  kubectl delete -n origin -f nginx_echo_origin.yaml --ignore-not-found

  log_section "Uninstalling lua configmap"
  uninstall_configmap_in_namespace $ingress_namespace "aaph-lua-plugin-files"

  log_section "Uninstalling registration token secret"
  uninstall_secret_in_namespace $ingress_namespace "aaph-token"

  log_section "Uninstalling docker image pull secret"
  uninstall_secret_in_namespace $ingress_namespace "aaph-acr"

  log_section "DONE"
}



# Run the main function
main "$@"
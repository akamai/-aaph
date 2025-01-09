#!/bin/bash

#set -e  # Exit immediately if a command exits with a non-zero status
set -o pipefail  # Pipeline will return the exit status of the last command to exit with a non-zero status
VERBOSE=false

#set -x
function usage {
    echo
    echo "This script automates the installation or upgrade of the NGINX Ingress controller with AAPH Lua plugin support."
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -f, --values-file <file>                    Path to the values.yaml file for configuring the Ingress controller"
    echo "  -l, --lua-file <file>                       Path to the Lua plugin file for the AAPH WAF plugin"
    echo "  -t, --reg-token <token>                     AAH Registration Token (required for the installation)"
    echo "  -r, --release-name <release-name>           Chart release name (default: nginx-ingress)"
    echo "  -k, --kubeconfig <file>                     Path to a new kubeconfig file (merges with existing kubeconfig and switches to the latest context)"
    echo "  -p, --docker-password <password>            Docker registry password for pulling images from $docker_acr_server"
    echo "  -v, --verbose                               Enable verbose output for detailed logging"
    echo "  -h, --help                                  Show this help message and exit"
    echo "  --install-origin                            Installation of the test origin(Juice Shop and NGINX Echo Server)"
    echo
    echo "Examples:"
    echo "# 1. Merge a new kubeconfig with the existing kubeconfig and switch to the latest context:"
    echo "  $0 -k /path/to/new/kubeconfig.yaml"
    echo
    echo "# 2. Install/upgrade the NGINX Ingress controller with the AAPH Lua plugin and install two origins:"
    echo "#    1. Juice Shop"
    echo "#    2. NGINX Echo Server"
    echo "  $0 -f aaph-values.yaml -l aaph.lua -r ingress-nginx -t 00J0HVZK0G00H0H0W00XRA0BPS -p asdersadfsaeradgaer --install-origin"
    echo
    echo "# 3. Install/upgrade the NGINX Ingress controller with the AAPH Lua plugin but skip origin installation:"
    echo "  $0 -f aaph-values.yaml -l aaph.lua -r ingress-nginx -t 00J0HVZK0G00H0H0W00XRA0BPS -p asdersadfsaeradgaer "
    echo
    echo "# 5. Install/upgrade the NGINX Ingress controller with latest app version "
    echo "  $0 -f aaph-values.yaml -l aaph.lua -r ingress-nginx -t 00J0HVZK0G00H0H0W00XRA0BPS -p asdersadfsaeradgaer"
    echo
    echo "Note:"
    echo "- Using the -k option will merge the new kubeconfig file with the existing one and switch to the latest context."
    echo "- This script is idempotent, meaning you can run it multiple times without triggering unnecessary changes."
    echo "- Updating the token alone will not restart the pods unless other significant changes are made."
}

step_count=0
hostname=""
pod_uid="unknown"
pod_name="unknown"
pod_status="unknown"

juiceshop_hostname=""
nginx_echo_hostname="aaph.backend.com"
ingress_nginx_app_version="" # Default is the latest version, set custom chart version if needed

docker_acr_server="aaphybrid.azurecr.io"
docker_acr_username="aaph-prodcution-acr-pull"
docker_acr_password=""

function log_success {
    local tick="✓"
    local green="\033[0;32m"
    local reset="\033[0m"
     ((step_count++))
  echo -e "${green}Step ${step_count}: $1 ${tick}${reset}"
  }

function log_fail {
    local cross="✖"
    local red="\033[0;31m"
    local reset="\033[0m"
    ((step_count++))
    echo -e "${red}Step ${step_count}: $1 ${cross}${reset}"
}

function log_verbose {
    if [ "$VERBOSE" = true ]; then
        echo "[INFO] $1"
    fi
}

function check_prerequisites() {
    log_verbose "Running Prerequisite checks..."
    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed. Ensure kubectl is installed" >&2
        exit 1
    fi

    if ! command -v helm &> /dev/null; then
        echo "Error: helm is not installed. Ensure helm client is installed" >&2
        exit 1
    fi
    log_success "Prerequisite checks completed"
}

merge_kubeconfig() {
    log_verbose "Update kubeconfig..."
    local new_kubeconfig="$1"

    mkdir -p ~/.kube
    local existing_kubeconfig=~/.kube/config
     if [ -f "$existing_kubeconfig" ]; then
        cp "$existing_kubeconfig" "$existing_kubeconfig.backup"
    else
        log_verbose "File $existing_kubeconfig does not exist. Skipping backup."
    fi

    if [ ! -f "$new_kubeconfig" ]; then
        log_fail "Failed to add new context from kubeconfig file $new_kubeconfig."
        echo "Error: New kubeconfig file '$new_kubeconfig' does not exist."
        exit 1
    fi

    KUBECONFIG=$existing_kubeconfig:$new_kubeconfig kubectl config view --flatten > /tmp/merged_kubeconfig
    mv /tmp/merged_kubeconfig $existing_kubeconfig
    chmod go-r ~/.kube/config
    log_verbose "Kubeconfig files merged successfully. Backup of the original config is available at '$existing_kubeconfig.backup'."

    log_verbose "Available contexts after merging:"
    log_verbose "$(kubectl config get-contexts)"
    local latest_context=$(KUBECONFIG=$new_kubeconfig kubectl config current-context)

    if [ -n "$latest_context" ]; then
        kubectl config use-context "$latest_context" > /dev/null
        if [ $? -eq 0 ]; then
            log_verbose "Switched to the latest context: $latest_context"
            log_success "Added new context $latest_context from kubeconfig file $new_kubeconfig"
        else
            log_fail "Failed to add new context from kubeconfig file $new_kubeconfig."
        fi
    else
        log_fail "Failed to add new context from kubeconfig file $new_kubeconfig."
        echo "No context found in the new kubeconfig."
        exit 1
    fi
}


function label_nodes() {
    log_verbose "label nodes..."
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
    if [ "$NODE_COUNT" -lt 2 ]; then
        echo "Error: The cluster must have at least 2 nodes to use nodeSelector based deployment" >&2
        exit 1
    fi

    INGRESS_NODE=$(kubectl get nodes -l test-node=ingress --no-headers | awk '{print $1}')
    if [ -z "$INGRESS_NODE" ]; then
        INGRESS_NODE=$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')
        kubectl label node "$INGRESS_NODE" test-node=ingress
        log_verbose "Labeled node $INGRESS_NODE with test-node=ingress"
    else
        log_verbose "Node $INGRESS_NODE already labeled with test-node=ingress"
    fi

    ORIGIN_NODE=$(kubectl get nodes -l test-node=origin --no-headers | awk '{print $1}')
    if [ -z "$ORIGIN_NODE" ]; then
        ORIGIN_NODE=$(kubectl get nodes --no-headers | grep -v "$INGRESS_NODE" | awk 'NR==1{print $1}')
        kubectl label node "$ORIGIN_NODE" test-node=origin
        log_verbose "Labeled node $ORIGIN_NODE with test-node=origin"
    else
        log_verbose "Node $ORIGIN_NODE already labeled with test-node=origin"
    fi
    log_success "label nodes completed"
}


function uninstall_exiting_chart {
    log_verbose "Uninstall existing chart..."
    helm uninstall -n $1 $2 --wait || log_verbose "release $2 not found in namespace $1"
    log_success "Uninstall existing chart"
}

function create_namespace {
    log_verbose "create namespace $1..."
    local namespace=$1
    if ! kubectl get ns $namespace > /dev/null 2>&1; then
        kubectl create ns $namespace > /dev/null
        log_verbose "Namespace $namespace created."
    else
        log_verbose "Namespace $namespace already exists."
    fi
}

function check_and_create_docker_pull_secret {
    log_verbose "create docker image pull secret..."
    local namespace=$1
    local secret_name=$2
    if kubectl get secret $secret_name -n $namespace > /dev/null 2>&1; then
        log_verbose "Docker secret $secret_name already exists in namespace $namespace. . Updating..."
        kubectl delete secret "${secret_name}" -n "${namespace}" >/dev/null
    else
        log_verbose "Docker secret $secret_name not found. Creating it."
    fi

    kubectl create secret docker-registry $secret_name \
        --namespace $namespace \
        --docker-server=$docker_acr_server \
        --docker-username=$docker_acr_username \
        --docker-password=$docker_acr_password > /dev/null
    if [ $? -eq 0 ]; then
        log_verbose "Docker image pull secret $secret_name created."
    else
        echo "Failed to create docker image pull secret in namespace $namespace."
    fi
#        log_success "Docker image pull secret created "
}

function create_or_update_token_secret() {
  log_verbose "create AAPH registration token secret..."
  local namespace=$1
  local secret_name=$2
  local token=$3

  # Check if the secret already exists
  if kubectl get secret "${secret_name}" -n "${namespace}" >/dev/null 2>&1; then
    log_verbose "Secret ${secret_name} exists. Updating..."
    kubectl delete secret "${secret_name}" -n "${namespace}" >/dev/null
  else
    log_verbose "Secret ${secret_name} does not exist. Creating..."
  fi

  # Create the secret with the REGISTRATION_CODE
  kubectl create secret generic "${secret_name}" \
    --from-literal=REGISTRATION_CODE="${token}" \
    -n "${namespace}" >/dev/null

  if [ $? -eq 0 ]; then
      log_verbose "Secret ${secret_name} has been created/updated in namespace ${namespace}."
  else
      echo "Failed to create registration token secret in namespace $namespace."
  fi
#  log_success "AAPH registration token secret created"
}

function create_or_update_lua_configmap {
    log_verbose "create lua plugin configmap..."
    local namespace=$1
    local lua_file=$2

    kubectl create configmap aaph-lua-plugin-files --from-file=$lua_file -n $namespace --dry-run=client -o yaml | kubectl apply -f - > /dev/null

    if [ $? -eq 0 ]; then
        log_verbose "ConfigMap aaph-lua-plugin-files created or updated with Lua file $lua_file in namespace $namespace."
    else
        echo "Failed to create or update ConfigMap aaph-lua-plugin-files in namespace $namespace. Ensure $lua_file is present"
    fi
#    log_success "Lua plugin ConfigMap created"

}

function install_ingress_nginx_chart {
    log_verbose "Helm deploy nginx ingress controller with AAPH Plugin..."
    local namespace=$1
    local release_name=$2
    local chart_repo=${3:-https://kubernetes.github.io/ingress-nginx}  # Default chart repo
    local values_file=${4:-}  # Path to values.yaml file (optional)
    local use_nodeSelector=${5:-false}

    helm repo add ingress-nginx $chart_repo > /dev/null
    helm repo update > /dev/null

    if [[ -n $values_file ]]; then
        if [ "$use_nodeSelector" = true ]; then
            if [[ -n $ingress_nginx_app_version ]]; then
                helm upgrade --install -n $namespace $release_name ingress-nginx/ingress-nginx -f $values_file --version=$ingress_nginx_app_version \
                    --set controller.nodeSelector.test-node=ingress \
                    --wait > /dev/null
            else
                helm upgrade --install -n $namespace $release_name ingress-nginx/ingress-nginx -f $values_file \
                    --set controller.nodeSelector.test-node=ingress \
                    --wait > /dev/null
            fi
        else
            if [[ -n $ingress_nginx_app_version ]]; then
                helm upgrade --install -n $namespace $release_name ingress-nginx/ingress-nginx -f $values_file --version=$ingress_nginx_app_version --wait > /dev/null
            else
                helm upgrade --install -n $namespace $release_name ingress-nginx/ingress-nginx -f $values_file --wait > /dev/null
            fi
        fi
    else
        if [ "$use_nodeSelector" = true ]; then
            if [[ -n $ingress_nginx_app_version ]]; then
                helm upgrade --install -n $namespace $release_name ingress-nginx/ingress-nginx --version=$ingress_nginx_app_version \
                    --set controller.nodeSelector.test-node=ingress \
                    --wait > /dev/null
            else
                helm upgrade --install -n $namespace $release_name ingress-nginx/ingress-nginx \
                    --set controller.nodeSelector.test-node=ingress \
                    --wait > /dev/null
            fi
        else
            if [[ -n $ingress_nginx_app_version ]]; then
                helm upgrade --install -n $namespace $release_name ingress-nginx/ingress-nginx --version=$ingress_nginx_app_version --wait > /dev/null
            else
                helm upgrade --install -n $namespace $release_name ingress-nginx/ingress-nginx --wait > /dev/null
            fi
        fi
    fi

    if [ $? -eq 0 ]; then
          log_verbose "Ingress NGINX chart installed or upgraded."
    else
        log_fail "Failed to install or upgrade the NGINX Ingress chart"
        echo "Nginx ingress controller helm deployment failed. Possible reasons for failure:"
        echo "1. Kubernetes cluster is not reachable or not initialized or timed out due to network connectivity."
        echo "2. Chart repository '$chart_repo' is not reachable."
        echo "3. Conflicting resources already exist in the namespace. Consider uninstalling existing release"
        echo "4. Incorrect or missing values in $values_file file"
        echo "5. Network policies or firewalls are blocking communication to the Kubernetes API."
        echo "Please check the above points and try again."
        exit 1
    fi
    log_success "NGINX Ingress Controller deployed with AAPH Plugin using Helm"

}

function install_origin {
    local use_nodeSelector=${1:-false}
    log_verbose "installing origin..."
    create_namespace "origin"
    log_verbose "installing juiceshop origin"

    if [ "$use_nodeSelector" = true ]; then
       helm upgrade --install -n origin juice-shop oci://ghcr.io/securecodebox/helm/juice-shop \
               --set ingress.enabled=true \
               --set "ingress.hosts[0].host=$juiceshop_hostname" \
               --set "ingress.hosts[0].paths[0].path=/" \
               --set nodeSelector.test-node=origin > /dev/null
    else
        helm upgrade --install -n origin juice-shop oci://ghcr.io/securecodebox/helm/juice-shop \
                --set ingress.enabled=true \
                --set "ingress.hosts[0].host=$juiceshop_hostname" \
                --set "ingress.hosts[0].paths[0].path=/" > /dev/null
    fi



    # Check if the helm command was successful
    if [[ $? -ne 0 ]]; then
        log_fail "Failed to install juiceshop origin"
        echo "Error: Failed to upgrade or install the Juice Shop Helm chart." >&2
    else
        log_verbose "Successfully upgraded or installed the Juice Shop origin."
    fi

    log_verbose "installing nginx echo origin"
    kubectl apply -n origin -f nginx_echo_origin.yaml > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        log_fail "Failed to install echo server origin"
        echo "Error: Failed to apply the ingress resource from nginx_echo_origin.yaml." >&2
    else
        log_verbose "Successfully upgraded or installed the echo server origin from nginx_echo_origin.yaml."
    fi
    log_success "Origin installation completed"
}

function verify_ingress_controller_deployment {
    local namespace=$1
    log_verbose "$(kubectl get pods -n $namespace)"
    log_success "Hybrid Protector Installed as Side-Car"
}

function wait_for_deployment {
    echo "Waiting $1 sec for Deployment to be Ready"
    local wait_time=$1
    sleep $wait_time
}

function send_request_to_ingress {
    log_verbose "Sending HTTP request to ingress..."
    local namespace=$1
    local juiceshop_ingress_hostname=""

    # Loop to get the ingress IP
    for i in {1..30}; do
        juiceshop_ingress_hostname=$(kubectl get ingress juice-shop -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
        if [[ -n "$juiceshop_ingress_hostname" ]]; then
            break
        fi
        echo "Waiting for Juice shop ingress hostname ... (attempt $i)"
        sleep $i
    done

    if [[ -n "$juiceshop_ingress_hostname" ]]; then
        log_verbose "Juice shop ingress hostname is $juiceshop_ingress_hostname"

        # First curl request to juice shop origin
        log_verbose "Sending curl request to juice shop origin"
        response1=$(curl -s -D - -o /dev/null -H "Pragma: akamai-x-get-extracted-values" ${juiceshop_hostname:+-H "Host: $juiceshop_hostname"} "http://$juiceshop_ingress_hostname")

        if [[ $? -ne 0 ]]; then
            log_fail "Failed to verify juiceshop ingress status"
            echo "Curl request to juice shop origin failed."
        else
            log_verbose "Response from juice shop origin:\n$response1"
        fi

        # Second curl request to nginx echo origin
        log_verbose "Sending curl request to nginx echo origin"
        response2=$(curl -s -D - -o /dev/null -H "Pragma: akamai-x-get-extracted-values" ${nginx_echo_hostname:+-H "Host: $nginx_echo_hostname"} "http://$juiceshop_ingress_hostname")

        if [[ $? -ne 0 ]]; then
            log_fail "Failed to verify echo server ingress status"
            echo "Curl request to nginx echo origin failed."
        else
            log_verbose "Response from nginx echo origin:\n$response2"
        fi

        log_verbose "Curl requests completed."
    else
        echo "Failed to get ingress IP,Possible reasons for failure:"
        echo "Failed to retrieve the public IP. Possible reasons for failure:"
        echo "1. The LoadBalancer service is still provisioning. Use kubectl get svc -A for status check"
        echo "2. cloud provider may not support LoadBalancer services."
        echo "3. Insufficient permissions to access the LoadBalancer's status."
        echo "4. Networking issues preventing communication with the LoadBalancer."
        echo "5. The ingress resource may not have been created correctly."
        echo "6. The Kubernetes cluster may be in a non-ready state."
        echo "7. Cloud provider quotas may have been exceeded, preventing the allocation of resources."
        echo "Please check the above points and try again."
        return 1
    fi

    log_success "Ingress status verified"
}

fetch_ingress_controller_hostname() {
    log_verbose "fetch AAPH ingress controller DNS Hostname..."
    local namespace="$1"
    local chart_name="$2"

    SERVICE_NAME=$(kubectl get svc -n "$namespace" -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}')
    if [ -n "$SERVICE_NAME" ]; then
        log_verbose "LoadBalancer Service Name: $SERVICE_NAME"
        hostname=$(kubectl get svc -n "$namespace" $SERVICE_NAME -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    else
        echo "No LoadBalancer service found for NGINX Ingress Controller in namespace $NAMESPACE."
        hostname=$(kubectl get svc -n "$namespace" "${chart_name}-ingress-nginx-controller" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    fi

    if [ -z "$hostname" ]; then
        log_fail "Failed to fetch nginx ingress controller hostname"
        echo "Failed to retrieve the Hostname. Check Ingress Controller Deployment Status."
    else
        log_verbose "AAPH ingress controller is deployed and can be accessed using http://$hostname"
    fi
}

fetch_aaph_instance_ID() {
  log_verbose "fetch aaph instance ID..."
  local namespace=$1
  local label_selector="app.kubernetes.io/component=controller"
  pod_name=$(kubectl get pods -n "$namespace" -l "$label_selector" -o jsonpath='{.items[0].metadata.name}')
  if [ -z "$pod_name" ]; then
    echo "No pod found with label $label_selector in namespace $namespace"
    return 1
  fi
  pod_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}')
  if [ $? -eq 0 ]; then
      log_verbose "Pod '$pod_name' status: $pod_status"
  else
      echo "Error: Unable to retrieve status for pod '$pod_name'."
  fi

  pod_uid=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.metadata.uid}')
  log_verbose "Pod Name: $pod_name"
  log_verbose "AAPH Instance ID is : $pod_uid"
}

function print_status {
    echo -e "\n----------------------------------------"
    echo -e "          Deployment Summary            "
    echo -e "----------------------------------------"
    if [ ! -z "$hostname" -a "$hostname" != " " ]; then
          echo -e "Ingress Hostname : http://$hostname"
    fi

#    echo -e "Ingress Hostname : http://$hostname"
    echo -e "Pod UID          : ${pod_uid}"
    echo -e "Pod Name         : ${pod_name}"
    echo -e "Pod Status       : ${pod_status}"
    echo -e "----------------------------------------"
}

function main {
    local chart_repo="https://kubernetes.github.io/ingress-nginx"
    local values_file=""
    local lua_file="aaph.lua"
    local reg_token="" # default
    local namespace="ingress-nginx"
    local chart_name=""
    local use_nodeSelector=false  # if enabled, ingress controller and origin will be installed in separate nodes
    local install_origin=false  # if true, juice shop origin and ingress will be installed
    local kubeconfig=""

     # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--release-name)
                chart_name="$2"
                shift 2
                ;;
            -f|--values-file)
                values_file="$2"
                shift 2
                ;;
            -l|--lua-file)
                lua_file="$2"
                shift 2
                ;;
            -t|--reg-token)
                reg_token="$2"
                shift 2
                ;;
            --install-origin)
                install_origin=true
                shift
                ;;
            -k|--kubeconfig)
                kubeconfig="$2"
                shift 2
                ;;
            -p|--docker-password)
                docker_acr_password="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    check_prerequisites
    if [[ -n "$kubeconfig" ]]; then
            merge_kubeconfig "$kubeconfig"
            exit 0
    fi
    if [ -z "$reg_token" ]; then
        echo "Error: -t <token> is required."
        usage
        exit 1
    fi
    if [ -z "$docker_acr_password" ]; then
        echo "Error: -p <docker password> is required."
        usage
        exit 1
    fi
    if [ -z "$lua_file" ]; then
            echo "Error: -l <lua plugin file> is required."
            usage
            exit 1
    fi
    if [ -z "$chart_name" ]; then
                echo "Error: -r <release name> is required."
                usage
                exit 1
    fi

#    uninstall_exiting_chart $namespace $chart_name  #uncomment to clean up before new installation
    if [ "$use_nodeSelector" = true ]; then
        label_nodes
    else
        log_verbose "skipping nodeSelector based Deployment."
    fi

    echo "Deploying NGINX Ingress Controller. This may take up to a minute..."
    create_namespace $namespace
    check_and_create_docker_pull_secret $namespace  "aaph-acr"

    if [[ -n $lua_file ]]; then
        create_or_update_lua_configmap $namespace  "$lua_file"
    fi

     if [[ -n $reg_token ]]; then
            create_or_update_token_secret $namespace  "aaph-token" "$reg_token"
    fi

    install_ingress_nginx_chart $namespace  $chart_name "$chart_repo" "$values_file" $use_nodeSelector
    verify_ingress_controller_deployment $namespace
#    wait_for_deployment 45 #wait until new IP is allocated

    if [ "$install_origin" = true ]; then
            install_origin $use_nodeSelector
            send_request_to_ingress "origin"
            fetch_ingress_controller_hostname $namespace $chart_name
    fi
    fetch_aaph_instance_ID $namespace
    print_status
}

# Run the main function
main "$@"
#!/usr/bin/env bash
# XIOPS - Azure Kubernetes Service Operations
# Deploy and manage applications on AKS

# =============================================
# Connect to AKS cluster
# =============================================
aks_connect() {
    print_section "🔗 Connecting to AKS"
    print_step "Getting AKS credentials..."

    if ! az aks get-credentials \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --overwrite-existing 2>/dev/null; then
        print_error "Failed to connect to AKS cluster"
        print_info "Try: az login"
        return 1
    fi

    print_success "Connected to AKS cluster: ${AKS_CLUSTER_NAME}"
    return 0
}

# =============================================
# Prepare namespace
# =============================================
aks_prepare_namespace() {
    local namespace="${1:-$NAMESPACE}"

    print_step "Preparing namespace: ${namespace}..."

    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

    print_success "Namespace ready: ${namespace}"
    return 0
}

# =============================================
# Process K8s manifests with envsubst
# =============================================
aks_process_manifests() {
    local k8s_dir="${XIOPS_PROJECT_DIR}/k8s"
    local processed_dir="${XIOPS_PROJECT_DIR}/.xiops-processed"

    if [[ ! -d "$k8s_dir" ]]; then
        print_error "k8s directory not found: $k8s_dir"
        return 1
    fi

    print_section "📝 Processing Kubernetes Manifests"

    # Create processed directory (don't modify source files)
    rm -rf "$processed_dir"
    mkdir -p "$processed_dir"

    # Export variables for envsubst
    export NAMESPACE
    export ACR_NAME
    export IMAGE_TAG
    export IMAGE_NAME="${IMAGE_NAME:-$SERVICE_NAME}"
    export SERVICE_NAME
    export WORKLOAD_IDENTITY_CLIENT_ID
    export KEY_VAULT_NAME
    export AZURE_TENANT_ID="${TENANT_ID}"

    # Process each yaml file to the processed directory
    local files=("kustomization.yaml" "deployment.yaml" "configmap.yaml" "service.yaml" "secret-provider-class.yaml" "hpa.yaml")

    for file in "${files[@]}"; do
        if [[ -f "${k8s_dir}/${file}" ]]; then
            print_step "Processing ${file}..."
            envsubst < "${k8s_dir}/${file}" > "${processed_dir}/${file}"
            print_success "${file} processed"
        fi
    done

    # Store processed dir for apply step
    export XIOPS_PROCESSED_DIR="$processed_dir"

    return 0
}

# =============================================
# Apply K8s manifests
# =============================================
aks_apply_manifests() {
    local k8s_dir="${XIOPS_PROCESSED_DIR:-${XIOPS_PROJECT_DIR}/k8s}"

    print_step "Applying manifests with kustomize..."

    if [[ -f "${k8s_dir}/kustomization.yaml" ]]; then
        kubectl apply -k "$k8s_dir"
    else
        # Fallback to applying all yaml files
        kubectl apply -f "$k8s_dir"
    fi

    print_success "All manifests applied"

    # Clean up processed directory
    if [[ -n "$XIOPS_PROCESSED_DIR" && -d "$XIOPS_PROCESSED_DIR" ]]; then
        rm -rf "$XIOPS_PROCESSED_DIR"
    fi

    # Force rollout restart to ensure new image is pulled
    local deployment="${SERVICE_NAME}"
    print_step "Triggering rollout restart for ${deployment}..."
    kubectl rollout restart "deployment/${deployment}" -n "$NAMESPACE" 2>/dev/null || true
    print_success "Rollout restart triggered"

    return 0
}

# =============================================
# Wait for deployment rollout
# =============================================
aks_wait_rollout() {
    local deployment="${1:-$SERVICE_NAME}"
    local namespace="${2:-$NAMESPACE}"
    local check_interval=5
    local timeout_seconds=300  # 5 minutes default
    local stuck_threshold=60   # Check stuck pods after 60 seconds

    print_section "⏳ Waiting for Deployment"

    local start_time=$(date +%s)

    # Wait briefly for pods to start creating
    sleep 3

    # Monitor pods until ready or error
    while true; do
        local elapsed=$(( $(date +%s) - start_time ))

        # Check timeout
        if [[ $elapsed -ge $timeout_seconds ]]; then
            print_error "Deployment timed out after ${timeout_seconds}s"
            aks_check_and_show_result "$deployment" "$namespace"
            return 1
        fi

        # Get pod status
        local pod_info
        pod_info=$(kubectl get pods -n "$namespace" -l "app=${deployment}" --no-headers -o wide 2>/dev/null)

        # Count ready pods
        local total_pods ready_pods
        if [[ -n "$pod_info" ]]; then
            total_pods=$(echo "$pod_info" | grep -c "." 2>/dev/null) || total_pods=0
            ready_pods=$(echo "$pod_info" | grep -c "Running.*1/1" 2>/dev/null) || ready_pods=0
        else
            total_pods=0
            ready_pods=0
        fi

        # Display current status
        echo ""
        echo -e "${BOLD}${WHITE}Pod Status (${elapsed}s elapsed):${NC}"
        if [[ -n "$pod_info" ]]; then
            echo "$pod_info" | while read -r line; do
                local pod_name ready status restarts age node
                pod_name=$(echo "$line" | awk '{print $1}')
                ready=$(echo "$line" | awk '{print $2}')
                status=$(echo "$line" | awk '{print $3}')
                restarts=$(echo "$line" | awk '{print $4}')
                age=$(echo "$line" | awk '{print $5}')
                node=$(echo "$line" | awk '{print $7}')

                local icon
                case "$status" in
                    Running)
                        if [[ "$ready" == "1/1" ]]; then
                            icon="${GREEN}✓${NC}"
                        else
                            icon="${YELLOW}◐${NC}"
                        fi
                        ;;
                    ContainerCreating|Pending)
                        icon="${YELLOW}◐${NC}"
                        ;;
                    *)
                        icon="${RED}✗${NC}"
                        ;;
                esac

                # Highlight restarts if > 0
                local restart_display="${DIM}${restarts}${NC}"
                if [[ "$restarts" != "0" ]]; then
                    restart_display="${YELLOW}${restarts}${NC}"
                fi

                # Truncate node name to 15 characters
                local node_short="${node:0:15}"
                if [[ "${#node}" -gt 15 ]]; then
                    node_short="${node_short}..."
                fi

                echo -e "  ${icon} ${CYAN}${pod_name}${NC} ${DIM}${ready}${NC} ${status} ${DIM}age:${NC}${age} ${DIM}restarts:${NC}${restart_display} ${DIM}${node_short}${NC}"
            done
        else
            echo -e "  ${YELLOW}No pods found${NC}"
        fi
        echo ""

        # Check if all pods are ready - run describe to verify
        if [[ "$ready_pods" -gt 0 && "$ready_pods" -eq "$total_pods" ]]; then
            aks_check_and_show_result "$deployment" "$namespace"
            return $?
        fi

        # Check for non-ready pods and run describe to check events
        if [[ -n "$pod_info" ]]; then
            local non_ready_pods
            non_ready_pods=$(echo "$pod_info" | grep -vE "Running.*1/1" || true)
            if [[ -n "$non_ready_pods" ]]; then
                # Run describe to check events for errors
                local check_result
                check_result=$(aks_check_events_for_errors "$deployment" "$namespace")

                if [[ "$check_result" == "error" ]]; then
                    # Error found - show full result with AI and menu
                    aks_show_error_result "$deployment" "$namespace"
                    return $?
                fi
                # No error yet - continue waiting
            fi
        fi

        # Wait before next check
        sleep $check_interval
    done
}

# =============================================
# Check events for errors (returns "error" or "ok")
# =============================================
aks_check_events_for_errors() {
    local deployment="$1"
    local namespace="$2"

    # Get the newest pod
    local target_pod
    target_pod=$(kubectl get pods -n "$namespace" -l "app=${deployment}" \
        --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | tail -1 | awk '{print $1}')

    if [[ -z "$target_pod" ]]; then
        echo "ok"
        return
    fi

    # Run describe and get events
    local events
    events=$(kubectl describe pod "$target_pod" -n "$namespace" 2>&1 | sed -n '/^Events:/,$ p')

    # Check for errors in events
    if echo "$events" | grep -qiE "Failed|Error|BackOff|not found|forbidden|denied|exceeded|unhealthy"; then
        echo "error"
    else
        echo "ok"
    fi
}

# =============================================
# Show success result
# =============================================
aks_check_and_show_result() {
    local deployment="$1"
    local namespace="$2"

    # Get the newest pod
    local target_pod
    target_pod=$(kubectl get pods -n "$namespace" -l "app=${deployment}" \
        --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | tail -1 | awk '{print $1}')

    # Run describe and get events
    local events
    events=$(kubectl describe pod "$target_pod" -n "$namespace" 2>&1 | sed -n '/^Events:/,$ p')

    # Check for errors in events
    if echo "$events" | grep -qiE "Failed|Error|BackOff|not found|forbidden|denied|exceeded|unhealthy"; then
        aks_show_error_result "$deployment" "$namespace"
        return $?
    fi

    # Success
    echo ""
    print_success "Deployment Success!"
    echo ""
    aks_show_hints "$deployment" "$namespace"
    return 0
}

# =============================================
# Show error result with AI and menu
# =============================================
aks_show_error_result() {
    local deployment="$1"
    local namespace="$2"

    # Get the newest pod
    local target_pod
    target_pod=$(kubectl get pods -n "$namespace" -l "app=${deployment}" \
        --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | tail -1 | awk '{print $1}')

    # Get events
    local events
    events=$(kubectl describe pod "$target_pod" -n "$namespace" 2>&1 | sed -n '/^Events:/,$ p')

    echo ""
    print_error "Deployment has errors"
    echo ""
    echo -e "${BOLD}${WHITE}Events for ${target_pod}:${NC}"
    echo "$events" | head -25
    echo ""

    # AI analysis if configured
    if ai_is_configured; then
        print_step "Analyzing with AI (${AI_PROVIDER})..."
        ai_analyze_pod_events "$target_pod" "$namespace"
        echo ""
    fi

    # Show menu
    aks_show_error_menu "$deployment" "$namespace"
    return $?
}

# =============================================
# Show deployment hints
# =============================================
aks_show_hints() {
    local deployment="$1"
    local namespace="$2"

    echo -e "${BOLD}${WHITE}Useful commands:${NC}"
    echo -e "  ${CYAN}xiops logs${NC}        - View pod logs"
    echo -e "  ${CYAN}xiops status${NC}      - Show deployment status"
    echo -e "  ${CYAN}xiops k shell${NC}     - Get shell access to pod"
    echo -e "  ${CYAN}xiops k describe${NC}  - Describe pod details"
    echo ""
}

# =============================================
# Show error menu
# =============================================
aks_show_error_menu() {
    local deployment="$1"
    local namespace="$2"

    echo -e "${BOLD}${WHITE}What would you like to do?${NC}"
    echo -e "  ${CYAN}1${NC}) Deploy Again"
    echo -e "  ${CYAN}2${NC}) Sync SPC (SecretProviderClass)"
    echo -e "  ${CYAN}3${NC}) Sync ConfigMap"
    echo -e "  ${CYAN}4${NC}) Cancel and Check Code"
    echo ""
    printf "Choice [1-4]: "
    read -r choice </dev/tty

    case "$choice" in
        1)
            print_info "Re-deploying..."
            kubectl rollout restart "deployment/${deployment}" -n "$namespace" 2>/dev/null
            aks_wait_rollout "$deployment" "$namespace"
            return $?
            ;;
        2)
            print_info "Syncing SPC..."
            aks_spc_from_env
            aks_sync_secrets_to_keyvault
            print_info "Re-deploying..."
            kubectl rollout restart "deployment/${deployment}" -n "$namespace" 2>/dev/null
            aks_wait_rollout "$deployment" "$namespace"
            return $?
            ;;
        3)
            print_info "Syncing ConfigMap..."
            aks_configmap_from_env
            print_info "Re-deploying..."
            kubectl rollout restart "deployment/${deployment}" -n "$namespace" 2>/dev/null
            aks_wait_rollout "$deployment" "$namespace"
            return $?
            ;;
        *)
            print_warning "Deployment cancelled"
            print_info "Check your code and run 'xiops deploy' when ready"
            return 1
            ;;
    esac
}

# =============================================
# Show deployment status
# =============================================
aks_show_status() {
    local namespace="${1:-$NAMESPACE}"
    local service="${2:-$SERVICE_NAME}"

    print_section "📊 Deployment Status"

    echo ""
    echo -e "${BOLD}${WHITE}  Pods:${NC}"
    kubectl get pods -n "$namespace" -l "app=${service}" -o wide --no-headers 2>/dev/null | while read -r line; do
        local pod_name ready status restarts age ip node
        pod_name=$(echo "$line" | awk '{print $1}')
        ready=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')
        restarts=$(echo "$line" | awk '{print $4}')
        age=$(echo "$line" | awk '{print $5}')
        ip=$(echo "$line" | awk '{print $6}')
        node=$(echo "$line" | awk '{print $7}')

        local status_icon
        if [[ "$status" == "Running" ]]; then
            status_icon="${GREEN}●${NC}"
        else
            status_icon="${YELLOW}●${NC}"
        fi

        # Truncate node name to 15 characters
        local node_short="${node:0:15}"
        if [[ "${#node}" -gt 15 ]]; then
            node_short="${node_short}..."
        fi

        echo -e "   ${status_icon} ${CYAN}${pod_name}${NC}"
        echo -e "      ${DIM}Ready:${NC} ${ready}  ${DIM}Status:${NC} ${status}  ${DIM}Restarts:${NC} ${restarts}  ${DIM}Age:${NC} ${age}"
        echo -e "      ${DIM}IP:${NC} ${ip}  ${DIM}Node:${NC} ${node_short}"
    done

    echo ""
    echo -e "${BOLD}${WHITE}  Services:${NC}"
    kubectl get svc -n "$namespace" -l "app=${service}" --no-headers 2>/dev/null | while read -r line; do
        local svc_name type cluster_ip port
        svc_name=$(echo "$line" | awk '{print $1}')
        type=$(echo "$line" | awk '{print $2}')
        cluster_ip=$(echo "$line" | awk '{print $3}')
        port=$(echo "$line" | awk '{print $5}')

        echo -e "   ${GREEN}●${NC} ${CYAN}${svc_name}${NC}"
        echo -e "      ${DIM}Type:${NC} ${type}  ${DIM}ClusterIP:${NC} ${cluster_ip}  ${DIM}Port:${NC} ${port}"
    done

    return 0
}

# =============================================
# Full deploy workflow
# =============================================
aks_deploy() {
    local tag="${1:-$IMAGE_TAG}"
    local skip_migrations="${SKIP_MIGRATIONS:-false}"

    # Set IMAGE_TAG for processing
    export IMAGE_TAG="$tag"

    # Connect to AKS
    aks_connect || return 1

    # Prepare namespace
    aks_prepare_namespace || return 1

    # Run migrations (unless skipped)
    if [[ "$skip_migrations" != "true" ]]; then
        if [[ -f "${XIOPS_PROJECT_DIR}/k8s/migration-job.yaml" ]]; then
            run_migration_job "$tag" || {
                print_error "Migration failed. Aborting deployment."
                print_info "Use --skip-migrations to deploy without migrations"
                return 1
            }
        else
            print_info "No migration-job.yaml found, skipping migrations"
        fi
    else
        print_warning "Skipping migrations (--skip-migrations flag)"
    fi

    # Process manifests
    aks_process_manifests || return 1

    # Apply manifests
    aks_apply_manifests || return 1

    # Wait for rollout
    aks_wait_rollout || return 1

    # Save deployed tag
    echo "$tag" > "${XIOPS_PROJECT_DIR}/deployed-image-tag.txt"
    print_info "Image tag saved to deployed-image-tag.txt"

    # Show status
    aks_show_status

    return 0
}

# =============================================
# Stream pod logs
# =============================================
aks_logs() {
    local namespace="${1:-$NAMESPACE}"
    local service="${2:-$SERVICE_NAME}"
    local follow="${3:-true}"

    local cmd="kubectl logs -n $namespace -l app=${service}"

    if [[ "$follow" == "true" ]]; then
        cmd="$cmd -f"
    fi

    print_info "Streaming logs for ${service}..."
    eval "$cmd"
}

# =============================================
# Rollback deployment
# =============================================
aks_rollback() {
    local deployment="${1:-$SERVICE_NAME}"
    local namespace="${2:-$NAMESPACE}"

    print_section "⏪ Rolling Back Deployment"

    print_step "Rolling back ${deployment}..."
    if kubectl rollout undo "deployment/${deployment}" -n "$namespace"; then
        print_success "Rollback initiated"

        print_step "Waiting for rollout..."
        kubectl rollout status "deployment/${deployment}" -n "$namespace" --timeout=5m
        print_success "Rollback complete"
    else
        print_error "Rollback failed"
        return 1
    fi

    return 0
}

# =============================================
# Scale deployment
# =============================================
aks_scale() {
    local replicas="$1"
    local deployment="${2:-$SERVICE_NAME}"
    local namespace="${3:-$NAMESPACE}"

    print_step "Scaling ${deployment} to ${replicas} replicas..."

    if kubectl scale "deployment/${deployment}" -n "$namespace" --replicas="$replicas"; then
        print_success "Scaled to ${replicas} replicas"
    else
        print_error "Failed to scale deployment"
        return 1
    fi

    return 0
}

# =============================================
# Restart deployment
# =============================================
aks_restart() {
    local deployment="${1:-$SERVICE_NAME}"
    local namespace="${2:-$NAMESPACE}"

    print_step "Restarting ${deployment}..."

    if kubectl rollout restart "deployment/${deployment}" -n "$namespace"; then
        print_success "Restart initiated"

        print_step "Waiting for rollout..."
        kubectl rollout status "deployment/${deployment}" -n "$namespace" --timeout=5m
        print_success "Restart complete"
    else
        print_error "Restart failed"
        return 1
    fi

    return 0
}

# =============================================
# Get shell access to pod
# =============================================
aks_shell() {
    local namespace="${1:-$NAMESPACE}"
    local service="${2:-$SERVICE_NAME}"
    local shell="${3:-/bin/bash}"

    local pod
    pod=$(kubectl get pod -n "$namespace" -l "app=${service}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$pod" ]]; then
        print_error "No pod found for ${service}"
        return 1
    fi

    print_info "Connecting to ${pod}..."
    kubectl exec -it -n "$namespace" "$pod" -- "$shell"
}

# =============================================
# Describe pod for debugging
# =============================================
aks_describe() {
    local namespace="${1:-$NAMESPACE}"
    local service="${2:-$SERVICE_NAME}"

    local pod
    pod=$(kubectl get pod -n "$namespace" -l "app=${service}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$pod" ]]; then
        print_error "No pod found for ${service}"
        return 1
    fi

    kubectl describe pod "$pod" -n "$namespace"
}

# =============================================
# Generate ConfigMap from .env file
# Uses inline comments to determine what goes where:
#   VAR=value # SECRET=NO  -> ConfigMap
#   VAR=value # SECRET=YES -> SecretProviderClass
# =============================================
aks_configmap_from_env() {
    local env_file="${1:-.env}"
    local configmap_name="${2:-${SERVICE_NAME}-config}"
    local namespace="${3:-$NAMESPACE}"
    local output_file="${4:-}"
    local apply="${5:-false}"

    if [[ ! -f "$env_file" ]]; then
        print_error "Env file not found: $env_file"
        return 1
    fi

    print_section "📋 Generating ConfigMap from ${env_file}"
    print_info "Looking for variables with # SECRET=NO"

    # Build the configmap YAML
    local configmap_yaml="apiVersion: v1
kind: ConfigMap
metadata:
  name: ${configmap_name}
  namespace: ${namespace}
data:"

    local count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comment-only lines
        if [[ -z "${line// }" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # Check if line has SECRET=NO (case insensitive, space after # optional)
        if [[ "$line" =~ \#[[:space:]]*SECRET[[:space:]]*=[[:space:]]*(NO|no|No|false|FALSE|False)[[:space:]]*$ ]]; then
            # Extract the var=value part (before the comment)
            local var_part="${line%%#*}"
            var_part="${var_part%% }"  # Trim trailing space

            # Extract key and value
            local key="${var_part%%=*}"
            local value="${var_part#*=}"

            # Remove quotes from value
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"
            value="${value%% }"  # Trim trailing space

            # Add to configmap
            configmap_yaml="${configmap_yaml}
  ${key}: \"${value}\""
            count=$((count + 1))
            print_step "Added: ${key}"
        fi

    done < "$env_file"

    if [[ $count -eq 0 ]]; then
        print_warning "No ConfigMap values found"
        print_info "Mark values with '# SECRET=NO' at end of line in .env"
        echo ""
        echo "Example .env format:"
        echo "  APP_ENV=production # SECRET=NO"
        echo "  LOG_LEVEL=info # SECRET=NO"
        echo "  DATABASE_URL=postgres://... # SECRET=YES"
        return 1
    fi

    print_success "Found ${count} ConfigMap values"

    # Always write to k8s/configmap.yaml
    local k8s_dir="${XIOPS_PROJECT_DIR}/k8s"
    local output_path="${k8s_dir}/configmap.yaml"

    # Create k8s dir if it doesn't exist
    mkdir -p "$k8s_dir"

    echo "$configmap_yaml" > "$output_path"
    print_success "ConfigMap written to: ${output_path}"
    print_info "Will be applied during 'xiops deploy'"

    return 0
}

# =============================================
# Generate SecretProviderClass from .env file
# Uses inline comments: VAR=value # SECRET=YES
# =============================================
aks_spc_from_env() {
    local env_file="${1:-.env}"
    local spc_name="${2:-${SERVICE_NAME}-spc}"
    local namespace="${3:-$NAMESPACE}"
    local output_file="${4:-}"
    local apply="${5:-false}"

    if [[ ! -f "$env_file" ]]; then
        print_error "Env file not found: $env_file"
        return 1
    fi

    print_section "🔐 Generating SecretProviderClass from ${env_file}"
    print_info "Looking for variables with # SECRET=YES"

    # Collect secret keys
    local secret_keys=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comment-only lines
        if [[ -z "${line// }" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # Check if line has SECRET=YES (case insensitive, space after # optional)
        if [[ "$line" =~ \#[[:space:]]*SECRET[[:space:]]*=[[:space:]]*(YES|yes|Yes|true|TRUE|True)[[:space:]]*$ ]]; then
            # Extract the var=value part (before the comment)
            local var_part="${line%%#*}"
            local key="${var_part%%=*}"
            key="${key%% }"  # Trim trailing space

            secret_keys+=("$key")
            print_step "Added: ${key}"
        fi

    done < "$env_file"

    if [[ ${#secret_keys[@]} -eq 0 ]]; then
        print_warning "No secrets found"
        print_info "Mark secrets with '# SECRET=YES' at end of line in .env"
        echo ""
        echo "Example .env format:"
        echo "  DATABASE_URL=postgres://... # SECRET=YES"
        echo "  API_KEY=xxx # SECRET=YES"
        return 1
    fi

    print_success "Found ${#secret_keys[@]} secrets"

    # Build objects array for SPC
    local objects_yaml=""
    for key in "${secret_keys[@]}"; do
        # Convert KEY_NAME to key-name for Key Vault
        local kv_name=$(echo "$key" | tr '_' '-' | tr '[:upper:]' '[:lower:]')
        objects_yaml="${objects_yaml}
        - |
          objectName: ${kv_name}
          objectType: secret
          objectAlias: ${key}"
    done

    # Build secretObjects for K8s secret sync
    local secret_data=""
    for key in "${secret_keys[@]}"; do
        local kv_name=$(echo "$key" | tr '_' '-' | tr '[:upper:]' '[:lower:]')
        secret_data="${secret_data}
        - objectName: ${kv_name}
          key: ${key}"
    done

    # Build the SPC YAML
    local spc_yaml="apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: ${spc_name}
  namespace: ${namespace}
spec:
  provider: azure
  secretObjects:
  - secretName: ${SERVICE_NAME}-secrets
    type: Opaque
    data:${secret_data}
  parameters:
    usePodIdentity: \"false\"
    useVMManagedIdentity: \"false\"
    clientID: \"\${WORKLOAD_IDENTITY_CLIENT_ID}\"
    keyvaultName: \"\${KEY_VAULT_NAME}\"
    tenantId: \"\${AZURE_TENANT_ID}\"
    objects: |
      array:${objects_yaml}"

    # Always write to k8s/secret-provider-class.yaml
    local k8s_dir="${XIOPS_PROJECT_DIR}/k8s"
    local output_path="${k8s_dir}/secret-provider-class.yaml"

    # Create k8s dir if it doesn't exist
    mkdir -p "$k8s_dir"

    echo "$spc_yaml" > "$output_path"
    print_success "SecretProviderClass written to: ${output_path}"
    print_info "Will be applied during 'xiops deploy'"

    return 0
}

# =============================================
# Sync SECRET=YES values to Azure Key Vault
# =============================================
aks_sync_secrets_to_keyvault() {
    local env_file="${1:-.env}"

    if [[ ! -f "$env_file" ]]; then
        print_error "Env file not found: $env_file"
        return 1
    fi

    if [[ -z "${KEY_VAULT_NAME:-}" ]]; then
        print_error "KEY_VAULT_NAME not set in .env"
        return 1
    fi

    print_section "🔐 Syncing Secrets to Azure Key Vault"
    print_info "Key Vault: ${KEY_VAULT_NAME}"
    print_info "Looking for variables with #SECRET=YES"
    echo ""

    local synced=0
    local skipped=0
    local failed=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comment-only lines
        if [[ -z "${line// }" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # Check if line has SECRET=YES
        if [[ "$line" =~ \#[[:space:]]*SECRET[[:space:]]*=[[:space:]]*(YES|yes|Yes|true|TRUE|True)[[:space:]]*$ ]]; then
            # Extract the var=value part (before the comment)
            local var_part="${line%%#*}"
            local key="${var_part%%=*}"
            local value="${var_part#*=}"

            # Trim spaces
            key="${key%% }"
            value="${value%% }"

            # Remove quotes from value
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"

            # Convert KEY_NAME to key-name for Key Vault
            local kv_name=$(echo "$key" | tr '_' '-' | tr '[:upper:]' '[:lower:]')

            print_step "Processing: ${key} -> ${kv_name}"

            # Check if secret already exists
            local existing_value
            existing_value=$(az keyvault secret show \
                --vault-name "$KEY_VAULT_NAME" \
                --name "$kv_name" \
                --query "value" -o tsv 2>/dev/null || echo "")

            if [[ -n "$existing_value" ]]; then
                if [[ "$existing_value" == "$value" ]]; then
                    print_info "  ↳ Already up to date, skipping"
                    skipped=$((skipped + 1))
                    continue
                else
                    print_warning "  ↳ Secret exists with different value"
                    if ! confirm "  Override ${kv_name}?"; then
                        print_info "  ↳ Skipped"
                        skipped=$((skipped + 1))
                        continue
                    fi
                fi
            fi

            # Set the secret
            local az_output
            local az_exit_code
            az_output=$(az keyvault secret set \
                --vault-name "$KEY_VAULT_NAME" \
                --name "$kv_name" \
                --value "$value" 2>&1) && az_exit_code=0 || az_exit_code=$?

            if [[ $az_exit_code -eq 0 ]]; then
                print_success "  ↳ Set: ${kv_name}"
                synced=$((synced + 1))
            else
                print_error "  ↳ Failed to set: ${kv_name}"
                echo -e "     ${RED}${az_output}${NC}"
                failed=$((failed + 1))
            fi
        fi

    done < "$env_file"

    echo ""
    print_section "📊 Sync Summary"
    echo -e "   ${GREEN}●${NC} Synced:  ${synced}"
    echo -e "   ${YELLOW}●${NC} Skipped: ${skipped}"
    if [[ $failed -gt 0 ]]; then
        echo -e "   ${RED}●${NC} Failed:  ${failed}"
    fi
    echo ""

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# =============================================
# Show current ConfigMap values
# =============================================
aks_configmap_show() {
    local configmap_name="${1:-${SERVICE_NAME}-config}"
    local namespace="${2:-$NAMESPACE}"

    print_section "📋 ConfigMap: ${configmap_name}"

    if ! kubectl get configmap "$configmap_name" -n "$namespace" &>/dev/null; then
        print_error "ConfigMap not found: $configmap_name"
        return 1
    fi

    kubectl get configmap "$configmap_name" -n "$namespace" -o yaml | grep -A 1000 "^data:" | tail -n +2
}

# =============================================
# Delete ConfigMap
# =============================================
aks_configmap_delete() {
    local configmap_name="${1:-${SERVICE_NAME}-config}"
    local namespace="${2:-$NAMESPACE}"

    print_step "Deleting ConfigMap: ${configmap_name}..."

    if kubectl delete configmap "$configmap_name" -n "$namespace"; then
        print_success "ConfigMap deleted"
    else
        print_error "Failed to delete ConfigMap"
        return 1
    fi
}

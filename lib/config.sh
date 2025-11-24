#!/usr/bin/env bash
# XIOPS - Configuration Management
# .env file parsing and validation

# =============================================
# Global configuration variables
# =============================================
XIOPS_CONFIG_LOADED=false
XIOPS_PROJECT_DIR=""

# Required variables for different operations
XIOPS_REQUIRED_BUILD="ACR_NAME SERVICE_NAME"

XIOPS_REQUIRED_DEPLOY="ACR_NAME AKS_CLUSTER_NAME RESOURCE_GROUP NAMESPACE SERVICE_NAME"

XIOPS_OPTIONAL_VARS="IMAGE_TAG IMAGE_NAME KEY_VAULT_NAME WORKLOAD_IDENTITY_CLIENT_ID TENANT_ID SUBSCRIPTION_ID"

# =============================================
# Find project root (directory containing .env)
# =============================================
find_project_root() {
    local dir="$PWD"

    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/.env" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done

    return 1
}

# =============================================
# Load .env file
# =============================================
load_env() {
    local env_file="${1:-.env}"
    local project_dir

    # If not absolute path, find project root
    if [[ "$env_file" != /* ]]; then
        project_dir=$(find_project_root) || {
            print_error "No .env file found in current directory or parent directories"
            return 1
        }
        env_file="$project_dir/.env"
        XIOPS_PROJECT_DIR="$project_dir"
    else
        XIOPS_PROJECT_DIR="$(dirname "$env_file")"
    fi

    if [[ ! -f "$env_file" ]]; then
        print_error ".env file not found: $env_file"
        return 1
    fi

    print_step "Loading configuration from .env..."

    # Parse .env file (compatible with both bash and zsh)
    set -a
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*#.*$ ]] && continue
        [[ -z "${line// }" ]] && continue

        # Remove carriage returns
        line=$(echo "$line" | tr -d '\r')

        # Only process lines that look like VAR=value
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            # Strip inline comments (#SECRET=YES/NO etc) but preserve the value
            # Handle: VAR=value #comment -> VAR=value
            local var_name="${line%%=*}"
            local var_value="${line#*=}"

            # Remove inline comment (everything after space+#)
            var_value="${var_value%% \#*}"
            var_value="${var_value%%	\#*}"  # Also handle tab+#

            # Remove quotes if present
            var_value="${var_value#\"}"
            var_value="${var_value%\"}"
            var_value="${var_value#\'}"
            var_value="${var_value%\'}"

            # Trim trailing whitespace
            var_value="${var_value%% }"
            var_value="${var_value%%	}"

            # Export the clean variable
            export "$var_name=$var_value" 2>/dev/null || true
        fi
    done < "$env_file"
    set +a

    XIOPS_CONFIG_LOADED=true
    print_success "Configuration loaded from: $env_file"
    return 0
}

# =============================================
# Validate required variables
# =============================================
validate_required() {
    local required="$1"
    local missing=""
    local has_missing=false

    for var in $required; do
        eval "val=\${$var:-}"
        if [[ -z "$val" ]]; then
            missing="$missing $var"
            has_missing=true
        fi
    done

    if $has_missing; then
        print_error "Missing required variables in .env:"
        for var in $missing; do
            print_bullet "$var"
        done
        return 1
    fi

    print_success "All required variables present"
    return 0
}

# =============================================
# Validate for build operation
# =============================================
validate_for_build() {
    validate_required "$XIOPS_REQUIRED_BUILD"
}

# =============================================
# Validate for deploy operation
# =============================================
validate_for_deploy() {
    validate_required "$XIOPS_REQUIRED_DEPLOY"
}

# =============================================
# Get configuration value with default
# =============================================
get_config() {
    local var="$1"
    local default="$2"

    if [[ -n "${!var}" ]]; then
        echo "${!var}"
    else
        echo "$default"
    fi
}

# =============================================
# Update .env file with new value
# =============================================
update_env() {
    local var="$1"
    local value="$2"
    local env_file="${XIOPS_PROJECT_DIR}/.env"

    if [[ ! -f "$env_file" ]]; then
        print_error ".env file not found"
        return 1
    fi

    # Check if variable exists
    if grep -q "^${var}=" "$env_file" 2>/dev/null; then
        # Update existing variable
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "s|^${var}=.*|${var}=${value}|" "$env_file"
        else
            sed -i "s|^${var}=.*|${var}=${value}|" "$env_file"
        fi
        print_success "Updated ${var} in .env"
    else
        # Add new variable
        echo "" >> "$env_file"
        echo "${var}=${value}" >> "$env_file"
        print_success "Added ${var} to .env"
    fi

    # Update exported variable
    export "${var}=${value}"
}

# =============================================
# Display current configuration
# =============================================
show_config() {
    local operation="${1:-all}"

    echo ""
    print_box_start
    print_box_title "Current Configuration"
    print_box_empty

    case "$operation" in
        build)
            print_box_line "ACR Name" "${ACR_NAME:-not set}"
            print_box_line "Service Name" "${SERVICE_NAME:-not set}"
            print_box_line "Image Name" "${IMAGE_NAME:-$SERVICE_NAME}"
            print_box_line "Image Tag" "${IMAGE_TAG:-auto-generated}"
            ;;
        deploy)
            print_box_line "ACR Name" "${ACR_NAME:-not set}"
            print_box_line "Service Name" "${SERVICE_NAME:-not set}"
            print_box_line "AKS Cluster" "${AKS_CLUSTER_NAME:-not set}"
            print_box_line "Resource Group" "${RESOURCE_GROUP:-not set}"
            print_box_line "Namespace" "${NAMESPACE:-not set}"
            print_box_line "Image Tag" "${IMAGE_TAG:-not set}"
            ;;
        *)
            print_box_line "Project Dir" "${XIOPS_PROJECT_DIR:-not set}"
            print_box_line "ACR Name" "${ACR_NAME:-not set}"
            print_box_line "Service Name" "${SERVICE_NAME:-not set}"
            print_box_line "Image Name" "${IMAGE_NAME:-$SERVICE_NAME}"
            print_box_line "AKS Cluster" "${AKS_CLUSTER_NAME:-not set}"
            print_box_line "Resource Group" "${RESOURCE_GROUP:-not set}"
            print_box_line "Namespace" "${NAMESPACE:-not set}"
            print_box_line "Image Tag" "${IMAGE_TAG:-not set}"
            print_box_line "Key Vault" "${KEY_VAULT_NAME:-not set}"
            ;;
    esac

    print_box_end
    echo ""
}

# =============================================
# Generate .env template
# =============================================
generate_env_template() {
    local output="${1:-.env.example}"

    cat > "$output" << 'EOF'
# =============================================
# XIOPS Configuration
# Project-specific settings for Azure deployment
# =============================================

# Service Configuration (Required)
SERVICE_NAME=my-service

# Azure Container Registry (Required for build)
ACR_NAME=your-acr-name

# Image Name (Optional - defaults to SERVICE_NAME if not set)
# IMAGE_NAME=my-image

# Azure Kubernetes Service (Required for deploy)
AKS_CLUSTER_NAME=your-aks-cluster
RESOURCE_GROUP=your-resource-group
NAMESPACE=your-namespace

# Image Tag (Optional - auto-generated if not set)
# IMAGE_TAG=v01

# Azure Identity (Optional)
# SUBSCRIPTION_ID=your-subscription-id
# TENANT_ID=your-tenant-id
# KEY_VAULT_NAME=your-keyvault
# WORKLOAD_IDENTITY_CLIENT_ID=your-client-id

# =============================================
# Application-specific settings below
# =============================================
EOF

    print_success "Generated .env template: $output"
}

# =============================================
# Get full image path
# =============================================
get_full_image_path() {
    local tag="${1:-$IMAGE_TAG}"
    local image_name="${IMAGE_NAME:-$SERVICE_NAME}"
    echo "${ACR_NAME}.azurecr.io/${image_name}:${tag}"
}

# =============================================
# Get image repository (without tag)
# =============================================
get_image_repository() {
    local image_name="${IMAGE_NAME:-$SERVICE_NAME}"
    echo "${ACR_NAME}.azurecr.io/${image_name}"
}

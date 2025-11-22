#!/usr/bin/env bash
# XIOPS - Azure Container Registry Operations
# Build and push Docker images to ACR

# =============================================
# Login to ACR
# =============================================
acr_login() {
    print_section "🔐 Azure Container Registry"
    print_step "Logging in to ACR: ${ACR_NAME}..."

    if ! az acr login --name "$ACR_NAME" 2>/dev/null; then
        print_error "Failed to login to ACR"
        print_info "Try: az login"
        return 1
    fi

    print_success "Logged in to ACR: ${ACR_NAME}"
    return 0
}

# =============================================
# Build Docker image
# =============================================
acr_build() {
    local tag="$1"
    local dockerfile="${2:-Dockerfile}"
    local context="${3:-.}"
    local full_image

    full_image=$(get_full_image_path "$tag")

    print_section "🔨 Building Docker Image"
    print_step "Building for linux/amd64 platform..."
    echo ""
    print_box_start
    print_box_title "Build Configuration"
    print_box_empty
    print_box_line "Image" "$full_image"
    print_box_line "Dockerfile" "$dockerfile"
    print_box_line "Context" "$context"
    print_box_line "Platform" "linux/amd64"
    print_box_end
    echo ""

    if ! docker buildx build \
        --platform linux/amd64 \
        -t "$full_image" \
        -f "$dockerfile" \
        --no-cache \
        --load \
        "$context"; then
        print_error "Docker build failed"
        return 1
    fi

    print_success "Docker image built: $full_image"

    # Tag as latest
    print_step "Tagging image as 'latest'..."
    local repo
    repo=$(get_image_repository)
    docker tag "$full_image" "${repo}:latest"
    print_success "Tagged as latest"

    return 0
}

# =============================================
# Push image to ACR
# =============================================
acr_push() {
    local tag="$1"
    local full_image
    local repo

    full_image=$(get_full_image_path "$tag")
    repo=$(get_image_repository)

    print_section "📤 Pushing to ACR"

    print_step "Pushing ${tag}..."
    if ! docker push "$full_image"; then
        print_error "Failed to push image"
        return 1
    fi
    print_success "Pushed: $full_image"

    print_step "Pushing latest..."
    if ! docker push "${repo}:latest"; then
        print_warning "Failed to push latest tag"
    else
        print_success "Pushed: ${repo}:latest"
    fi

    return 0
}

# =============================================
# Full build and push workflow
# =============================================
acr_build_and_push() {
    local tag="$1"

    # Login to ACR
    acr_login || return 1

    # Build image
    acr_build "$tag" || return 1

    # Push to ACR
    acr_push "$tag" || return 1

    # Save built tag
    echo "$tag" > "${XIOPS_PROJECT_DIR}/built-image-tag.txt"
    print_info "Image tag saved to built-image-tag.txt"

    return 0
}

# =============================================
# Get currently deployed image from K8s
# =============================================
get_deployed_image() {
    local namespace="${1:-$NAMESPACE}"
    local service="${2:-$SERVICE_NAME}"
    local image

    image=$(kubectl get pods \
        -l "app=${service}" \
        -n "$namespace" \
        -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)

    echo "$image"
}

# =============================================
# Get deployed tag from K8s
# =============================================
get_deployed_tag() {
    local image
    image=$(get_deployed_image "$@")

    if [[ -n "$image" ]]; then
        echo "$image" | sed 's/.*://'
    fi
}

# =============================================
# Prompt for new image tag
# =============================================
prompt_image_tag() {
    local current_tag="$1"
    local suggested_num="01"
    local current_num
    local next_num

    print_section "🏷️  Enter New Image Tag"
    echo ""

    # Calculate suggested version
    if [[ -n "$current_tag" ]]; then
        current_num=$(extract_version_number "$current_tag")
        if [[ -n "$current_num" ]]; then
            suggested_num=$(increment_version "$current_num")
        fi
    fi

    echo -e "   ${DIM}Image tag format:${NC} ${CYAN}v${NC}${GREEN}<number>${NC}"
    echo -e "   ${DIM}Suggested next:${NC} ${GREEN}${suggested_num}${NC} ${DIM}(will become v${suggested_num})${NC}"
    echo ""
    echo -ne "   ${BOLD}${WHITE}Enter version number ${NC}${DIM}[${suggested_num}]${NC}${BOLD}${WHITE}: v${NC}"
    read -r user_num

    # Use suggested if empty
    if [[ -z "$user_num" ]]; then
        user_num="$suggested_num"
    fi

    # Format and return tag
    format_version_tag "$user_num"
}

# =============================================
# Show deployment status
# =============================================
show_deployment_status() {
    local namespace="${NAMESPACE:-default}"
    local service="${SERVICE_NAME}"
    local k8s_image=""
    local current_tag=""
    local last_built_tag=""
    local env_tag=""

    print_section "📦 Current Deployment Status"
    echo ""

    # Try to get from Kubernetes
    print_step "Fetching deployed image from Kubernetes..."
    k8s_image=$(get_deployed_image "$namespace" "$service")

    if [[ -n "$k8s_image" ]]; then
        current_tag=$(echo "$k8s_image" | sed 's/.*://')
        print_success "Connected to Kubernetes cluster"
    else
        print_warning "Could not connect to Kubernetes, using local files"
        if [[ -f "${XIOPS_PROJECT_DIR}/deployed-image-tag.txt" ]]; then
            current_tag=$(cat "${XIOPS_PROJECT_DIR}/deployed-image-tag.txt" 2>/dev/null | tr -d '\n\r')
        fi
    fi

    # Check for built-image-tag.txt
    if [[ -f "${XIOPS_PROJECT_DIR}/built-image-tag.txt" ]]; then
        last_built_tag=$(cat "${XIOPS_PROJECT_DIR}/built-image-tag.txt" 2>/dev/null | tr -d '\n\r')
    fi

    # Get .env IMAGE_TAG
    env_tag="$IMAGE_TAG"

    echo ""
    print_box_start
    print_box_title "Image Repository"
    echo -e "   ${GRAY}│${NC}  ${CYAN}$(get_image_repository)${NC}"
    print_box_empty
    print_box_title "Tag Information"

    if [[ -n "$k8s_image" ]]; then
        echo -e "   ${GRAY}│${NC}  ${DIM}Full Image (K8s):${NC}    ${CYAN}${k8s_image}${NC}"
    fi

    if [[ -n "$current_tag" ]]; then
        echo -e "   ${GRAY}│${NC}  ${DIM}Currently Deployed:${NC}  ${GREEN}${current_tag}${NC} ${DIM}(live)${NC}"
    else
        echo -e "   ${GRAY}│${NC}  ${DIM}Currently Deployed:${NC}  ${YELLOW}Unknown${NC}"
    fi

    if [[ -n "$last_built_tag" && "$last_built_tag" != "$current_tag" ]]; then
        echo -e "   ${GRAY}│${NC}  ${DIM}Last Built:${NC}          ${CYAN}${last_built_tag}${NC}"
    fi

    if [[ -n "$env_tag" && "$env_tag" != "$current_tag" ]]; then
        echo -e "   ${GRAY}│${NC}  ${DIM}.env IMAGE_TAG:${NC}      ${MAGENTA}${env_tag}${NC}"
    fi

    print_box_end
    echo ""

    # Return current tag for use
    echo "$current_tag"
}

# =============================================
# List images in ACR
# =============================================
acr_list_tags() {
    local repo="${SERVICE_NAME}"
    local limit="${1:-10}"

    print_step "Fetching tags from ACR..."

    az acr repository show-tags \
        --name "$ACR_NAME" \
        --repository "$repo" \
        --orderby time_desc \
        --top "$limit" \
        --output table 2>/dev/null || {
        print_warning "Could not fetch tags from ACR"
        return 1
    }
}

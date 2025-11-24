#!/usr/bin/env bash
# XIOPS - AI-Powered Error Analysis
# Supports: Claude, OpenAI, Ollama

# =============================================
# Check if AI is configured
# =============================================
ai_is_configured() {
    [[ -n "${AI_PROVIDER:-}" ]]
}

# =============================================
# Analyze Kubernetes error with AI
# =============================================
ai_analyze_error() {
    local error_text="$1"
    local context="${2:-kubernetes deployment}"

    if ! ai_is_configured; then
        return 1
    fi

    local prompt="You are a Kubernetes expert. Analyze this error and provide:
1. ISSUE: One line describing the problem
2. CAUSE: Why this happened
3. FIX: Step by step solution
4. COMMAND: The xiops command to fix it (if applicable)

Available xiops commands:
- xiops configmap - Generate ConfigMap from .env (SECRET=NO vars)
- xiops spc - Generate SecretProviderClass from .env (SECRET=YES vars)
- xiops spc sync - Sync secrets to Azure Key Vault
- xiops deploy - Deploy to AKS
- xiops rollback - Rollback deployment

Context: ${context}

Error/Events:
${error_text}

Respond in this exact format:
ISSUE: <issue>
CAUSE: <cause>
FIX: <fix>
COMMAND: <command or 'none'>"

    local response=""
    local provider_lower
    provider_lower=$(echo "$AI_PROVIDER" | tr '[:upper:]' '[:lower:]')

    case "$provider_lower" in
        claude|anthropic)
            response=$(ai_call_claude "$prompt")
            ;;
        openai|chatgpt|gpt)
            response=$(ai_call_openai "$prompt")
            ;;
        ollama|local)
            response=$(ai_call_ollama "$prompt")
            ;;
        *)
            print_warning "Unknown AI provider: ${AI_PROVIDER}"
            return 1
            ;;
    esac

    if [[ -n "$response" ]]; then
        echo "$response"
        return 0
    else
        return 1
    fi
}

# =============================================
# Call Claude API
# =============================================
ai_call_claude() {
    local prompt="$1"
    local api_key="${AI_API_KEY:-${ANTHROPIC_API_KEY:-}}"
    local model="${AI_MODEL:-claude-sonnet-4-20250514}"

    if [[ -z "$api_key" ]]; then
        print_warning "AI_API_KEY not set for Claude"
        return 1
    fi

    local response
    response=$(curl -s --max-time 30 \
        "https://api.anthropic.com/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${api_key}" \
        -H "anthropic-version: 2023-06-01" \
        -d "$(jq -n \
            --arg model "$model" \
            --arg prompt "$prompt" \
            '{
                model: $model,
                max_tokens: 500,
                messages: [{role: "user", content: $prompt}]
            }')" 2>/dev/null)

    # Extract text from response
    echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null
}

# =============================================
# Call OpenAI API
# =============================================
ai_call_openai() {
    local prompt="$1"
    local api_key="${AI_API_KEY:-${OPENAI_API_KEY:-}}"
    local model="${AI_MODEL:-gpt-4o-mini}"

    if [[ -z "$api_key" ]]; then
        print_warning "AI_API_KEY not set for OpenAI"
        return 1
    fi

    local response
    response=$(curl -s --max-time 30 \
        "https://api.openai.com/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${api_key}" \
        -d "$(jq -n \
            --arg model "$model" \
            --arg prompt "$prompt" \
            '{
                model: $model,
                max_tokens: 500,
                messages: [{role: "user", content: $prompt}]
            }')" 2>/dev/null)

    # Extract text from response
    echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null
}

# =============================================
# Call Ollama (local)
# =============================================
ai_call_ollama() {
    local prompt="$1"
    local model="${AI_MODEL:-llama3.2}"
    local ollama_url="${OLLAMA_URL:-http://localhost:11434}"

    # Check if Ollama is running
    if ! curl -s --max-time 2 "${ollama_url}/api/tags" >/dev/null 2>&1; then
        print_warning "Ollama not running at ${ollama_url}"
        print_info "Start with: ollama serve"
        return 1
    fi

    local response
    response=$(curl -s --max-time 60 \
        "${ollama_url}/api/generate" \
        -d "$(jq -n \
            --arg model "$model" \
            --arg prompt "$prompt" \
            '{
                model: $model,
                prompt: $prompt,
                stream: false
            }')" 2>/dev/null)

    # Extract text from response
    echo "$response" | jq -r '.response // empty' 2>/dev/null
}

# =============================================
# Display AI analysis result
# =============================================
ai_display_analysis() {
    local analysis="$1"

    if [[ -z "$analysis" ]]; then
        return 1
    fi

    echo ""
    echo -e "${BOLD}${MAGENTA}🤖 AI Analysis:${NC}"
    echo ""

    # Parse and display each field
    local issue cause fix command

    issue=$(echo "$analysis" | grep -i "^ISSUE:" | sed 's/^ISSUE:[[:space:]]*//')
    cause=$(echo "$analysis" | grep -i "^CAUSE:" | sed 's/^CAUSE:[[:space:]]*//')
    fix=$(echo "$analysis" | grep -i "^FIX:" | sed 's/^FIX:[[:space:]]*//')
    command=$(echo "$analysis" | grep -i "^COMMAND:" | sed 's/^COMMAND:[[:space:]]*//')

    if [[ -n "$issue" ]]; then
        echo -e "   ${BOLD}Issue:${NC} ${RED}${issue}${NC}"
    fi

    if [[ -n "$cause" ]]; then
        echo -e "   ${BOLD}Cause:${NC} ${cause}"
    fi

    if [[ -n "$fix" ]]; then
        echo -e "   ${BOLD}Fix:${NC} ${fix}"
    fi

    if [[ -n "$command" && "$command" != "none" ]]; then
        echo ""
        echo -e "   ${BOLD}Suggested command:${NC}"
        echo -e "   ${CYAN}\$ ${command}${NC}"
    fi

    echo ""
}

# =============================================
# Quick analyze pod events
# =============================================
ai_analyze_pod_events() {
    local pod_name="$1"
    local namespace="${2:-$NAMESPACE}"

    # Get pod events
    local events
    events=$(kubectl describe pod "$pod_name" -n "$namespace" 2>/dev/null | \
        sed -n '/^Events:/,$ p' | head -30)

    if [[ -z "$events" ]]; then
        return 1
    fi

    # Get pod status
    local status
    status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)

    local context="Pod: ${pod_name}, Status: ${status}, Namespace: ${namespace}"

    # Call AI
    local analysis
    analysis=$(ai_analyze_error "$events" "$context")

    if [[ -n "$analysis" ]]; then
        ai_display_analysis "$analysis"
        return 0
    fi

    return 1
}

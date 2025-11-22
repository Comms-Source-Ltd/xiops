# XIOPS

A simple, project-agnostic deployment CLI for Azure Container Registry (ACR) and Azure Kubernetes Service (AKS).

Built by **[XIOTS](https://xiots.io)** - A Software Development and Digital Marketing Agency.

**Used by our team and available to all professionals** who want simplified deployments to Azure AKS clusters without complicated deployment systems like Helm, ArgoCD, or Flux.

## Features

- **Simple Build & Deploy** - Build Docker images and deploy to AKS with a single command
- **Smart Image Tagging** - Prompts for image tag and shows currently deployed version for easy tracking
- **Azure Key Vault Integration** - Securely manage secrets with built-in Key Vault commands
- **kubectl Wrapper** - Common kubectl operations without remembering namespace flags
- **Rolling Updates** - Safe deployments with rollback support
- **Real-time Logs** - Stream pod logs directly from CLI
- **Shell Access** - Quick access to running pods for debugging

## Installation

### Homebrew (Recommended)

```bash
brew tap Comms-Source-Ltd/xiops https://github.com/Comms-Source-Ltd/xiops
brew install xiops
```

### Manual Installation

```bash
git clone https://github.com/xiots/xiops.git
cd xiops
chmod +x xiops lib/*.sh

# Add to PATH
export PATH="$PATH:$(pwd)"

# Or create symlink
ln -s $(pwd)/xiops /usr/local/bin/xiops
```

## Quick Start

1. Navigate to your project directory
2. Initialize configuration:
   ```bash
   xiops init
   ```
3. Edit `.env` with your project settings
4. Build and deploy:
   ```bash
   xiops release
   ```

## Commands

| Command | Description |
|---------|-------------|
| `xiops build` | Build and push Docker image to ACR |
| `xiops deploy` | Deploy to AKS cluster |
| `xiops release` | Build and deploy (combined) |
| `xiops status` | Show current deployment status |
| `xiops logs` | Stream pod logs |
| `xiops rollback` | Rollback to previous deployment |
| `xiops restart` | Restart the deployment |
| `xiops shell` | Get shell access to pod |
| `xiops init` | Initialize .env template |
| `xiops config` | Show current configuration |
| `xiops kv` | Azure Key Vault operations |
| `xiops k` | kubectl wrapper commands |

### Key Vault Commands (`xiops kv`)

| Command | Description |
|---------|-------------|
| `xiops kv list` | List all secrets in Key Vault |
| `xiops kv get <name>` | Get a secret value |
| `xiops kv set <name> <value>` | Set a secret |
| `xiops kv delete <name>` | Delete a secret |
| `xiops kv info <name>` | Show secret metadata |
| `xiops kv sync` | Sync .env secrets to Key Vault |
| `xiops kv export` | Export secrets to .env format |

### kubectl Commands (`xiops k`)

| Command | Description |
|---------|-------------|
| `xiops k pods` | List pods in namespace |
| `xiops k logs` | Get logs from all pods |
| `xiops k exec` | Exec into a pod |
| `xiops k scale <n>` | Scale deployment |
| `xiops k events` | Get namespace events |
| `xiops k describe` | Describe deployment |
| `xiops k restart` | Rolling restart |
| `xiops k debug` | Debug pod info |

## Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-v, --version` | Show version |
| `-t, --tag TAG` | Specify image tag |

## Configuration

XIOPS reads configuration from a `.env` file in your project directory.

### Required Variables

```bash
# Service Configuration
SERVICE_NAME=my-service

# Azure Container Registry
ACR_NAME=your-acr-name

# Azure Kubernetes Service (required for deploy)
AKS_CLUSTER_NAME=your-aks-cluster
RESOURCE_GROUP=your-resource-group
NAMESPACE=your-namespace
```

### Optional Variables

```bash
# Image tag (auto-generated if not set)
IMAGE_TAG=v01

# Azure Identity
SUBSCRIPTION_ID=your-subscription-id
TENANT_ID=your-tenant-id
KEY_VAULT_NAME=your-keyvault
WORKLOAD_IDENTITY_CLIENT_ID=your-client-id
```

## Project Structure

XIOPS expects your project to have:

```
your-project/
├── .env                    # Configuration (required)
├── Dockerfile             # Docker build file (required)
└── k8s/                   # Kubernetes manifests (required for deploy)
    ├── deployment.yaml
    ├── service.yaml
    ├── configmap.yaml
    └── kustomization.yaml
```

## Examples

### Build with interactive tag prompt
```bash
xiops build
```

**Example Output:**
```
╭─────────────────────────────────────────────────────╮
│  XIOPS - Build                                      │
│  Service: my-api                                    │
╰─────────────────────────────────────────────────────╯

→ Currently deployed: v14
→ Enter image tag [v15]: v15

→ Logging into ACR: myregistry.azurecr.io
✓ ACR login successful

→ Building Docker image...
✓ Build complete

→ Pushing to ACR...
✓ Push complete

╭─────────────────────────────────────────────────────╮
│  ✓ Build Successful                                 │
├─────────────────────────────────────────────────────┤
│  Image: myregistry.azurecr.io/my-api:v15            │
╰─────────────────────────────────────────────────────╯
```

### Deploy with specific tag
```bash
xiops deploy -t v15
```

**Example Output:**
```
╭─────────────────────────────────────────────────────╮
│  XIOPS - Deploy                                     │
│  Service: my-api                                    │
╰─────────────────────────────────────────────────────╯

→ Currently deployed: v14
→ Deploying: v15

→ Connecting to AKS cluster: my-cluster
✓ Connected to AKS

→ Applying Kubernetes manifests...
✓ Manifests applied

→ Waiting for rollout...
✓ Rollout complete

╭─────────────────────────────────────────────────────╮
│  ✓ Deployment Successful                            │
├─────────────────────────────────────────────────────┤
│  Service    : my-api                                │
│  Namespace  : production                            │
│  Image Tag  : v15                                   │
│  Replicas   : 3/3 ready                             │
╰─────────────────────────────────────────────────────╯
```

### Full release (build + deploy)
```bash
xiops release
```

### Check deployment status
```bash
xiops status
```

### Stream logs
```bash
xiops logs
```

### Rollback to previous version
```bash
xiops rollback
```

## Dependencies

XIOPS requires the following tools to be installed:

- **Azure CLI** (`az`) - For ACR/AKS authentication
- **kubectl** - For Kubernetes operations
- **Docker** - For building images
- **bash 4+** - For script execution

Install dependencies via Homebrew:
```bash
brew install azure-cli kubernetes-cli docker
```

## Authentication

Before using XIOPS, ensure you are logged into Azure:

```bash
az login
```

For AKS access, XIOPS will automatically fetch credentials using:
```bash
az aks get-credentials --resource-group <rg> --name <cluster>
```

## About XIOTS

**[XIOTS](https://xiots.io)** is a Software Development and Digital Marketing Agency specializing in:

- Cloud-native application development
- Azure & Kubernetes infrastructure
- DevOps automation and CI/CD
- Digital marketing solutions

XIOPS was created to streamline our internal deployment workflows. We use it daily across all our projects and have open-sourced it so that **any professional can simplify their Azure AKS deployments** without the complexity of tools like Helm, ArgoCD, or Flux.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - Copyright (c) 2024 XIOTS
# xiops

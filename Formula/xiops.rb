class Xiops < Formula
  desc "Project-agnostic deployment CLI for Azure Container Registry and AKS"
  homepage "https://github.com/xiots/xiops"
  url "https://github.com/xiots/xiops/archive/refs/tags/v1.1.2.tar.gz"
  sha256 "6168561e41223c457c3aa2be1e50810526ded8cffa52855609ec22993ad79db1"
  license "MIT"
  version "1.1.2"

  depends_on "azure-cli"
  depends_on "kubernetes-cli"
  depends_on "bash" => :recommended

  def install
    # Install all files to libexec
    libexec.install Dir["*"]

    # Create executable wrapper in bin
    bin.write_exec_script (libexec/"xiops")
  end

  def caveats
    <<~EOS
      XIOPS requires a .env file in your project directory with:
        - SERVICE_NAME: Name of your service
        - ACR_NAME: Azure Container Registry name
        - AKS_CLUSTER_NAME: AKS cluster name
        - RESOURCE_GROUP: Azure resource group
        - NAMESPACE: Kubernetes namespace

      Ensure you are logged into Azure CLI:
        az login

      Initialize a new project:
        xiops init
    EOS
  end

  test do
    assert_match "XIOPS", shell_output("#{bin}/xiops --help")
    assert_match version.to_s, shell_output("#{bin}/xiops --version")
  end
end

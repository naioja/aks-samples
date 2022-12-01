# Copy the latest Releases to shell's search path.
mkdir -p ~/bin
export PATH="$PATH:~/bin"

wget "https://github.com/Azure/kubelogin/releases/download/v0.0.24/kubelogin-linux-amd64.zip" \
    -O /tmp/kubelogin.zip

unzip -d ~/bin/ /tmp/kubelogin.zip && rm /tmp/kubelogin.zip
chmod +x ~/bin/kubelogin 

# demo functionality
export KUBECONFIG="~/.kube/config"
kubelogin convert-kubeconfig
kubectl get no
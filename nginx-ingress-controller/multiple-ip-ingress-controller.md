# This is an example of one nginx ingress controller installation in AKS using two different IP classes and IP ACLs

1. Create the static public IP address in the AKS managed resource group using the Standard SKU:

```bash
#The below command creates an IP address that will be deleted if you delete your AKS cluster. 
#Alternatively, you can create an IP address in a different resource group which can be 
#managed separately from your AKS cluster. If you create an IP address in a different resource group, 
#ensure the service principal used by the AKS cluster has delegated permissions to the other resource group, 
#such as Network Contributor.

az network public-ip create \
    --resource-group MC_myResourceGroup_myAKSCluster_eastus \
    --name ingress-pub-ipaddress \
    --sku Standard \
    --allocation-method static \
    --query publicIp.ipAddress -o tsv
```
2. Create your AKS ingress namespace:

```bash
kubectl create namespace ingress-basic
```

3. Deploy the ingress controller using a static pre-provisioned public IP address as well as a secondary internal IP located on an Azure ILB:

```bash
# The specified IP address must reside in the same subnet as the AKS cluster and 
# must not already be assigned to a resource
STATIC_PRV_IP='10.240.0.4'

# Populating the variable with the value of the public IP address created earlier
STATIC_PUB_IP="$(az network public-ip show \
  --resource-group MC_policy-rg_policy-aks_westeurope \
  --name ingress-pub-ipaddress --query ipAddress -o tsv)"

# Meaningful dns name for your project
DNS_LABEL='fta-team'

# Contents of internal-ingress.yaml file is a bit different when deploying as a secondary IP 
cat <<EOF > internal-ingress.yaml
controller:
  loadBalancerIP: $STATIC_PRV_IP
  service:
    internal:
      enabled: true
      annotations:
        service.beta.kubernetes.io/azure-load-balancer-internal: "true"
EOF

helm install nginx-ingress ingress-nginx/ingress-nginx \
    --namespace ingress-basic \
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux  \
    --set controller.service.loadBalancerIP="$STATIC_PUB_IP" \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"="$DNS_LABEL"
    -f internal-ingress.yaml
```

The result of the helm deployment should be similar to the following output:

```bash
k get services -n ingress-basic
NAME                                               TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)                      AGE
aks-helloworld                                     ClusterIP      10.0.34.150    <none>          80/TCP                       4d4h
aks-nginx                                          ClusterIP      10.0.217.135   <none>          80/TCP                       4d3h
ingress-demo                                       ClusterIP      10.0.77.155    <none>          80/TCP                       4d4h
nginx-ingress-ingress-nginx-controller             LoadBalancer   10.0.66.177    20.XXX.XXX.XXX  80:30235/TCP,443:30331/TCP   4d4h
nginx-ingress-ingress-nginx-controller-admission   ClusterIP      10.0.152.143   <none>          443/TCP                      4d4h
nginx-ingress-ingress-nginx-controller-internal    LoadBalancer   10.0.21.191    10.240.0.4      80:32063/TCP,443:32128/TCP   4d
```

## IP whitelisting internal and external resources
One issue with the example above is that presumably the application an engineer would want to server just to internal customers will be also availible on the public IP.

In order to apply the **OPTIONAL IP ACLs** we will need to enable client source IP preservation for requests to containers in your cluster.One way to do that is to add `--set controller.service.externalTrafficPolicy=Local` to the Helm install/upgrade command. The client source IP is stored in the request header under X-Forwarded-For. When using an ingress controller with client source IP preservation enabled, TLS pass-through will not work. Different cloud provides offer different ways of preserving X-Forwarded-For, in Azure Application Gateway would be the way to go.

| WARNING: Having this setting for your ingress controller should be carefully considered as it changes the default traffic pattern. 
| --- |

```bash 
# Upgrade the existing installation with the new option
helm upgrade nginx-ingress ingress-nginx/ingress-nginx \
    --namespace ingress-basic \
    --set controller.replicaCount=2 \
    --set controller.service.externalTrafficPolicy=Local \
    --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux  \
    --set controller.service.loadBalancerIP="$STATIC_PUB_IP" \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"="$DNS_LABEL"
    -f internal-ingress.yaml
```

1. For my "internal" example I've deployed the simplest workload possible:

```bash
cat <<EOF | kubectl apply -f -
---
 apiVersion: apps/v1
 kind: Deployment
 metadata:
   name: aks-nginx
 spec:
   selector:
     matchLabels:
       app: aks-nginx
   replicas: 1
   template:
     metadata:
       labels:
         app: aks-nginx
     spec:
       containers:
       - name: aks-nginx
         image: nginx:1.14.2
         ports:
         - containerPort: 80
 ---
 apiVersion: v1
 kind: Service
 metadata:
   name: aks-nginx
 spec:
   type: ClusterIP
   ports:
   - port: 80
   selector:
     app: aks-nginx
EOF
```

Creating the ingress for my "internal app" using the annotation `nginx.ingress.kubernetes.io/whitelist-source-range` will allow traffic only from the comma separated configured IP ranges.

```bash
STATIC_PRV_RANGE='10.240.0.0/16'

cat <<EOF | kubectl apply -f -
---
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: hello-world-ingress-internal
  namespace: ingress-basic
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$1
    nginx.ingress.kubernetes.io/whitelist-source-range: "$STATIC_PRV_RANGE"
spec:
  rules:
  - host: priv-app.example.org
    http:
      paths:
      - backend:
          serviceName: aks-nginx
          servicePort: 80
        path: /
EOF
```

In the example above the host `priv-app.example.org` is only configured inside my AKS cluster using the core-dns host plugin:

```bash
STATIC_PRV_IP='10.240.0.4'
HOST='priv-app.example.org'

cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom # this is the name of the configmap you can overwrite with your changes
  namespace: kube-system
data:
    test.override: |
          hosts example.hosts example.org {
              $STATIC_PRV_IP $HOST
              fallthrough
          }
EOF
```

One way to test if the ACLs are applied correctly is to create a pod and attach a terminal session:

```bash
kubectl run --rm -it --image=alpine ingress-test --namespace ingress-basic

# once in the container run:
wget -qO- --timeout=5 http://priv-app.example.org

# trimmed output of the wget command
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
    body {
[...]
```

2. For the "public app" I took the example from the Azure docs: https://docs.microsoft.com/en-us/azure/aks/ingress-basic#run-demo-applications

```bash
cat <<EOF | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-helloworld-one  
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aks-helloworld-one
  template:
    metadata:
      labels:
        app: aks-helloworld-one
    spec:
      containers:
      - name: aks-helloworld-one
        image: neilpeterson/aks-helloworld:v1
        ports:
        - containerPort: 80
        env:
        - name: TITLE
          value: "Welcome to Azure Kubernetes Service (AKS)"
---
apiVersion: v1
kind: Service
metadata:
  name: aks-helloworld-one  
spec:
  type: ClusterIP
  ports:
  - port: 80
  selector:
    app: aks-helloworld-one
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-helloworld-two  
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aks-helloworld-two
  template:
    metadata:
      labels:
        app: aks-helloworld-two
    spec:
      containers:
      - name: aks-helloworld-two
        image: neilpeterson/aks-helloworld:v1
        ports:
        - containerPort: 80
        env:
        - name: TITLE
          value: "AKS Ingress Demo"
---
apiVersion: v1
kind: Service
metadata:
  name: aks-helloworld-two  
spec:
  type: ClusterIP
  ports:
  - port: 80
  selector:
    app: aks-helloworld-two
EOF
```

For the "public facing" ingress controller I've used the same annotation `nginx.ingress.kubernetes.io/whitelist-source-range` this time allowing a different set of comma separated IP ranges.

```bash
# To get your current IP address
USER_IP="$(curl https://hazip.azurewebsites.net)"
DNS_LABEL='fta-team'
AZURE_REGION='westeurope.cloudapp.azure.com'

cat <<EOF | kubectl apply -f -
---
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: hello-world-ingress-public
  namespace: ingress-basic
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$1
    nginx.ingress.kubernetes.io/whitelist-source-range: "$USER_IP/32"
spec:
  rules:
  - host: $DNS_LABEL.$AZURE_REGION
    http:
      paths:
      - backend:
          serviceName: aks-helloworld
          servicePort: 80
        path: /hello-world-one(/|$)(.*)
      - backend:
          serviceName: ingress-demo
          servicePort: 80
        path: /hello-world-two(/|$)(.*)
      - backend:
          serviceName: aks-helloworld
          servicePort: 80
        path: /(.*)
EOF
```

To test if this ingress works should be straight forward by running a curl request from your current shell:

```bash
curl -L http://$DNS_LABEL.$AZURE_REGION

<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <link rel="stylesheet" type="text/css" href="/static/default.css">
    <title>Welcome to Azure Kubernetes Service (AKS)</title>
[...]
```

The below output shows a denied request:

```bash
DNS_LABEL='fta-team'
AZURE_REGION='westeurope.cloudapp.azure.com'

curl -L http://$DNS_LABEL.$AZURE_REGION
```
Output: 
```html
<html>
<head><title>403 Forbidden</title></head>
<body>
<center><h1>403 Forbidden</h1></center>
<hr><center>nginx/1.19.2</center>
</body>
</html>
```

## Resouces :
- https://docs.microsoft.com/en-us/azure/aks/ingress-internal-ip
- https://docs.microsoft.com/en-us/azure/aks/ingress-static-ip
- https://docs.microsoft.com/en-us/azure/aks/static-ip
- https://docs.microsoft.com/en-us/azure/aks/coredns-custom#hosts-plugin
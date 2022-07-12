# src: https://hodo.dev/posts/post-27-gcp-using-neg/

#gcloud config set project your-gcp-project ; gcloud config get project

# First lets define some variables:
PROJECT_ID=$(gcloud config list project --format='value(core.project)') ; echo $PROJECT_ID
ZONE=europe-west2-b ; echo $ZONE
CLUSTER_NAME=negs-lb ; echo $CLUSTER_NAME

# and we need a cluster
gcloud container clusters create $CLUSTER_NAME --zone $ZONE --machine-type "e2-medium" --enable-ip-alias --num-nodes=2

# the --enable-ip-alias enables the VPC-native traffic routing option for your cluster. This option creates and attaches additional subnets to VPC, the pods will have IP address allocated from the VPC subnets, and in this way the pods can be addressed directly by the load balancer aka container-native load balancing.

# Next we need a simple deployment, we will use nginx
cat << EOF > app-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
EOF
kubectl apply -f app-deployment.yaml

# and the service
cat << EOF > app-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: app-service
  annotations:
    cloud.google.com/neg: '{"exposed_ports": {"80":{"name": "app-service-80-neg"}}}'
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: nginx
EOF
kubectl apply -f app-service.yaml

# this annotation cloud.google.com/neg tells the GKE to create a NEG for this service and to add and remove endpoints (pods) to this group.
# Notice here that the type is ClusterIP. Yes it is possible to expose the service to the internet even if the type is ClusterIP. This one of the magic of NEGs.
# You can check if the NEG was created by using next command
gcloud compute network-endpoint-groups list

# Next let’s create the load balancer and all the required components.
# We need a firewall rule that will allow the traffic from the load balancer

# find the network tags used by our cluster
NETWORK_TAGS=$(gcloud compute instances describe \
    $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') \
    --zone=$ZONE --format="value(tags.items[0])")
echo $NETWORK_TAGS

# create the firewall rule
gcloud compute firewall-rules create $CLUSTER_NAME-lb-fw \
    --allow tcp:80 \
    --source-ranges 130.211.0.0/22,35.191.0.0/16 \
    --target-tags $NETWORK_TAGS

# and a health check configuration
gcloud compute health-checks create http app-service-80-health-check \
  --request-path / \
  --port 80 \
  --check-interval 60 \
  --unhealthy-threshold 3 \
  --healthy-threshold 1 \
  --timeout 5

# and a backend service
gcloud compute backend-services create $CLUSTER_NAME-lb-backend \
  --health-checks app-service-80-health-check \
  --port-name http \
  --global \
  --enable-cdn \
  --connection-draining-timeout 300

# next we need to add our NEG to the backend service
gcloud compute backend-services add-backend $CLUSTER_NAME-lb-backend \
  --network-endpoint-group=app-service-80-neg \
  --network-endpoint-group-zone=$ZONE \
  --balancing-mode=RATE \
  --capacity-scaler=1.0 \
  --max-rate-per-endpoint=1.0 \
  --global

# This was the backend configuration, let’s setup also the fronted.
# First the url map
gcloud compute url-maps create $CLUSTER_NAME-url-map --default-service $CLUSTER_NAME-lb-backend

# and then the http proxy
gcloud compute target-http-proxies create $CLUSTER_NAME-http-proxy --url-map $CLUSTER_NAME-url-map

# and finally the global forwarding rule

gcloud compute forwarding-rules create $CLUSTER_NAME-forwarding-rule \
  --global \
  --ports 80 \
  --target-http-proxy $CLUSTER_NAME-http-proxy

# Done! Give some time for the load balancer to setup all the components and then you can test if your setup works as expected.

# get the public ip address
IP_ADDRESS=$(gcloud compute forwarding-rules describe $CLUSTER_NAME-forwarding-rule --global --format="value(IPAddress)")
# print the public ip address
echo $IP_ADDRESS
# make a request to the service
curl -s -I http://$IP_ADDRESS/

# and the output should be similar to this
HTTP/1.1 200 OK
Server: nginx/1.21.0

# You can now control the options of the Cloud CDN, like disable the negative caching.

gcloud compute backend-services update $CLUSTER_NAME-lb-backend \
  --no-negative-caching \
  --global

# You can find out more about the limitations of the standalone zonal NEGs from the here Container-native load balancing through standalone zonal NEGs and pay a special attention to NEGs leaks:

# When a GKE service is deleted, the associated NEG will not be garbage collected if the NEG is still referenced by a backend service. Dereference the NEG from the backend service to allow NEG deletion.
# When a cluster is deleted, standalone NEGs are not deleted.


######################
# cleanup
# delete the forwarding-rule aka frontend
gcloud -q compute forwarding-rules delete $CLUSTER_NAME-forwarding-rule --global
# delete the http proxy
gcloud -q compute target-http-proxies delete $CLUSTER_NAME-http-proxy
# delete the url map
gcloud -q compute url-maps delete $CLUSTER_NAME-url-map
# delete the backend
gcloud -q compute backend-services delete $CLUSTER_NAME-lb-backend --global
# delete the health check
gcloud -q compute health-checks delete app-service-80-health-check
# delete the firewall rule
gcloud -q compute firewall-rules delete $CLUSTER_NAME-lb-fw
# delete the cluster
gcloud -q container clusters delete $CLUSTER_NAME --zone=$ZONE
# delete the NEG  
gcloud compute network-endpoint-groups delete app-service-80-neg --zone=$ZONE

#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: app-migrate.sh OLD_APP_NAME NEW_APP_NAME"
    exit 1
fi

OLD_APP_NAME=$1
NEW_APP_NAME=$2

# Get the names of the deploys.
echo "Getting the names of the deploys..."
OLD_DEPLOY=$(k3s kubectl get deploy -n ix-$OLD_APP_NAME | grep $OLD_APP_NAME | awk '{print $1}')
NEW_DEPLOY=$(k3s kubectl get deploy -n ix-$NEW_APP_NAME | grep $OLD_APP_NAME | awk '{print $1}')

if [ -z "$OLD_DEPLOY" ] || [ -z "$NEW_DEPLOY" ]; then
    echo "Failed to retrieve deploy names"
    exit 1
fi

# Scale down both apps
echo "Scaling down both apps..."
k3s kubectl scale deploy $OLD_DEPLOY -n ix-$OLD_APP_NAME --replicas=0
k3s kubectl scale deploy $OLD_APP_NAME -n ix-$OLD_APP_NAME --replicas=0

# Get the PVCs names and paths
echo "Getting the names and paths of PVCs..."
OLD_PVCS=$(k3s kubectl get pvc -n ix-$OLD_APP_NAME | grep -v postgres | grep -v redis | grep -v cnpg | awk '{print $1}')
NEW_PVCS=$(k3s kubectl get pvc -n ix-$NEW_APP_NAME | grep -v postgres | grep -v redis | grep -v cnpg | awk '{print $1}')

if [ -z "$OLD_PVCS" ] || [ -z "$NEW_PVCS" ]; then
    echo "Failed to retrieve PVC names and paths"
    exit 1
fi

OLD_PVC_PATH=$(zfs list | grep pvc | grep legacy | grep $OLD_APP_NAME | awk '{print $1}')
NEW_PVC_PATH=$(zfs list | grep pvc | grep legacy | grep $NEW_APP_NAME | awk '{print $1}')

if [ -z "$OLD_PVC_PATH" ] || [ -z "$NEW_PVC_PATH" ]; then
    echo "Failed to retrieve ZFS paths"
    exit 1
fi

# Destroy new PVCs and copy over old PVCs
echo "Copying over old PVCs to new PVCs..."
for pvc_path in $NEW_PVC_PATH; do
    zfs destroy $pvc_path
done

for pvc in $OLD_PVCS; do
    echo "Copying over $pvc..."
    zfs snapshot $OLD_PVC_PATH/$pvc@migrate
    zfs send $OLD_PVC_PATH/$pvc@migrate | zfs recv $NEW_PVC_PATH/$pvc@migrate
    zfs set mountpoint=legacy $NEW_PVC_PATH/$pvc
done

# Scale up both apps
echo "Scaling up both apps..."
k3s kubectl scale deploy $OLD_DEPLOY -n ix-$OLD_APP_NAME --replicas=1
k3s kubectl scale deploy $OLD_APP_NAME -n ix-$OLD_APP_NAME --replicas=1

echo "Migrate completed successfully!"

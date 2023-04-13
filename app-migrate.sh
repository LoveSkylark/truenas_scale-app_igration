#!/bin/bash

# use app-migrate.sh [-f] OLD NEW

FORCE=false
if [[ "$1" == "-f" ]]; then
    FORCE=true
    shift
fi

APP_NAME="$1"
NEW_APP_NAME="$2"

# Get namespaces that contain dbcreds or cnpg-main-urls secrets
namespaces=$(k3s kubectl get secrets -A | grep -E "dbcreds|cnpg-main-urls" | awk '{print $1}')

# Check if the app is using Postgres by looking for its namespace in the list of namespaces
if ! $FORCE && echo "$namespaces" | grep -qw "ix-$APP_NAME"; then
    echo "App $APP_NAME is using a Postgres DB, this script can not move the database connection."
    echo "You can run 'app-migrate.sh -f OLD NEW' to force the script to continue"
    exit 0
fi

# Get the names of the deploys.
OLD_DEPLOY=$(k3s kubectl get deploy -n ix-$APP_NAME | grep $APP_NAME | awk '{print $1}')
NEW_DEPLOY=$(k3s kubectl get deploy -n ix-$NEW_APP_NAME | grep $APP_NAME | awk '{print $1}')

if [ -z "$OLD_DEPLOY" ] || [ -z "$NEW_DEPLOY" ]; then
    echo "Failed to retrieve deploy names"
    exit 1
fi

echo "OLD deploy name:"
echo "$OLD_DEPLOY"
echo "NEW deploy name:"
echo "$NEW_DEPLOY"
echo ""

# Scale down both apps
echo "Scaling down both apps"
k3s kubectl scale deploy $OLD_DEPLOY -n ix-$APP_NAME --replicas=0
k3s kubectl scale deploy $NEW_DEPLOY -n ix-$NEW_APP_NAME --replicas=0
echo ""

# Get the PVCs names and paths
OLD_PVCS=$(k3s kubectl get pvc -n ix-$APP_NAME | grep -v postgres | grep -v redis | grep -v cnpg | grep -v NAME | awk '{print $1}')
NEW_PVCS=$(k3s kubectl get pvc -n ix-$NEW_APP_NAME | grep -v postgres | grep -v redis | grep -v cnpg | grep -v NAME | awk '{print $1}')

if [ -z "$OLD_PVCS" ] || [ -z "$NEW_PVCS" ]; then
    echo "Failed to retrieve PVC names and paths"
    exit 1
fi

echo "OLD PVCs:"
echo "$OLD_PVCS"
echo "NEW PVCs:"
echo "$NEW_PVCS"
echo ""

OLD_PVC_PATH=$(zfs list | grep pvc | grep legacy | grep $APP_NAME | awk '{print $1}')
NEW_PVC_PATH=$(zfs list | grep pvc | grep legacy | grep $NEW_APP_NAME | awk '{print $1}')

if [ -z "$OLD_PVC_PATH" ] || [ -z "$NEW_PVC_PATH" ]; then
    echo "Failed to retrieve ZFS paths"
    exit 1
fi

echo "OLD PVC path:"
echo "$OLD_PVC_PATH"
echo "NEW PVC path:"
echo "$NEW_PVC_PATH"
echo ""

exit 0

# Destroy new PVCs and copy over old PVCs
echo "Destroying new PVCs and copying over old PVCs"
for pvc_path in $NEW_PVC_PATH; do
    echo "Destroying PVC: $pvc_path"
    zfs destroy $pvc_path
done

for pvc in $OLD_PVCS; do
    echo "Taking snapshot of OLD PVC: $OLD_PVC_PATH/$pvc"
    zfs snapshot $OLD_PVC_PATH/$pvc@migrate
    echo "Copying OLD PVC snapshot to NEW PVC: $NEW_PVC_PATH/$pvc"
    zfs send $OLD_PVC_PATH/$pvc@migrate | zfs recv $NEW_PVC_PATH/$pvc@migrate
    echo "Setting mountpoint to legacy for NEW PVC: $NEW_PVC_PATH/$pvc"
    zfs set mountpoint=legacy $NEW_PVC_PATH/$pvc
done
echo ""

# Scale up both apps
echo "Scaling up both apps"
k3s kubectl scale deploy $OLD_DEPLOY -n ix-$APP_NAME --replicas=1
k3s kubectl scale deploy $NEW_DEPLOY -n ix-$NEW_APP_NAME --replicas=1
echo ""

# Wait for both apps to be ready
echo "Waiting for both apps to be ready"
k3s kubectl rollout status deploy/$OLD_DEPLOY -n ix-$APP_NAME
k3s kubectl rollout status deploy/$NEW_DEPLOY -n ix-$NEW_APP_NAME
echo ""

echo "Migration completed successfully!"

#!/bin/bash

#!/bin/bash

# use app-migrate.sh [-f] OLD NEW

FORCE=false
if [[ "$1" == "-f" ]]; then
    FORCE=true
    shift
fi

APP_NAME="$1"
NEW_APP_NAME="$2"

# Check if Postgres DB exists
if ! $FORCE && psql -lqt | cut -d \| -f 1 | grep -qw $APP_NAME; then
    echo "App $APP_NAME is using a Postgres DB, this script can not move the databse connection."
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

echo "OLD deploy name: $OLD_DEPLOY"
echo "NEW deploy name: $NEW_DEPLOY"

# Scale down both apps
echo "Scaling down both apps"
k3s kubectl scale deploy $OLD_DEPLOY -n ix-$APP_NAME --replicas=0
k3s kubectl scale deploy $APP_NAME -n ix-$APP_NAME --replicas=0

# Get the PVCs names and paths
OLD_PVCS=$(k3s kubectl get pvc -n ix-$APP_NAME | grep -v postgres | grep -v redis | grep -v cnpg | awk '{print $1}')
NEW_PVCS=$(k3s kubectl get pvc -n ix-$NEW_APP_NAME | grep -v postgres | grep -v redis | grep -v cnpg | awk '{print $1}')

if [ -z "$OLD_PVCS" ] || [ -z "$NEW_PVCS" ]; then
    echo "Failed to retrieve PVC names and paths"
    exit 1
fi

echo "OLD PVCs: $OLD_PVCS"
echo "NEW PVCs: $NEW_PVCS"

OLD_PVC_PATH=$(zfs list | grep pvc | grep legacy | grep $APP_NAME | awk '{print $1}')
NEW_PVC_PATH=$(zfs list | grep pvc | grep legacy | grep $NEW_APP_NAME | awk '{print $1}')

if [ -z "$OLD_PVC_PATH" ] || [ -z "$NEW_PVC_PATH" ]; then
    echo "Failed to retrieve ZFS paths"
    exit 1
fi

echo "OLD PVC path: $OLD_PVC_PATH"
echo "NEW PVC path: $NEW_PVC_PATH"

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

# Scale up both apps
echo "Scaling up both apps"
k3s kubectl scale deploy $OLD_DEPLOY -n ix-$APP_NAME --replicas=1
k3s kubectl scale deploy $APP_NAME -n ix-$APP_NAME --replicas=1

echo "Migration completed successfully"

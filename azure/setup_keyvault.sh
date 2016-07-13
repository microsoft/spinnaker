#!/bin/bash
set -e
set -o pipefail

# This script will execute the Azure CLI needed to create a default Spinnker 
# Resource group, enable the KeyVault provider, create a default Key Vault, and 
# add the appropriate secrets, with permissions, to the vault  

# Inputs
#   - Service Principal Name
#   - Resource Group (default: SpinnakerDefault)
#   - Region
#   - Key Vault name
#   - VM username
#   - VM Password

function usage {
    echo "Usage: setup_keyvault.sh -s <service_principal_name> [-u <VM_username>] [-p <VM_Password>] [-a <AppID>] -h"      
}

DEFAULT_RESOURCE_GROUP="SpinnakerDefault"
DEFAULT_KEY_VAULT="SpinnakerVault"
DEFAULT_REGION="eastus"

DEBUG=0
SPN=""
UNAME="SpinnakerAdmin"
PWD="sp!nn8kEr"
APPID=""

# parse parameters
while getopts ":s:u:p:a:dh" opt; do
    case "${opt}" in
        s)
            SPN=${OPTARG}
            ;;
        u)
            UNAME=${OPTARG}
            ;;
        p)
            PWD=${OPTARG}
            ;;
        a)
            APPID=${OPTARG}            
            ;;
        d)            
            DEBUG=1        
            ;;
        h)            
            usage
            exit
            ;;
        \?)
            echo -e \\n"Option -${BOLD}$OPTARG${NORM} not allowed"
            usage
            exit 1
            ;;
    esac
done

if [[ $DEBUG -gt 0 ]]; then
    echo "Service Principal Name: $SPN"
    echo "VM Username: $UNAME"
    echo "VM Password: $PWD"
    echo "App ID: $APPID"    
fi

if [[ ((-z "$SPN") && (-z "$APPID")) ]]; then
    echo "You must supply either the Service Principal Name or the Application ID"
    usage
    exit 1
fi 

# Query account information to see if the user is still logged in
TENANT_ID=`azure account show --json | jq '.[].tenantId'`

if [[ -z TENANT_ID ]]; then
    # if we can't get the account information then it's assumed we are not logged in
    echo "Unable to access account information. Aborting...."
    exit $?
fi

# Create the Resource Group
#   Required:
#    - Resource Group Name 
#    - Region (default: East-US)
echo "Create Resource Group $DEFAULT_RESOURCE_GROUP in Region $DEFAULT_REGION"
SUCCESS=`azure group create $DEFAULT_RESOURCE_GROUP $DEFAULT_REGION --json | jq '.properties.provisioningState'`
rc=$?
if [[ $rc -gt 0 ]]; then
    echo "Create Resource Group operation failed"    
    if [[ "$SUCCESS" -ne "enabled" ]]; then
        echo "Provisioning State: $SUCCESS"
    fi
    exit $rc
fi

# Register the Azure KeyVault Provider
# The register command does not return any json 
echo "Registering KeyVault provider"
eval 'azure provider register Microsoft.KeyVault --json'
rc=$?
if [[ $rc -gt 0 ]]; then
    echo "Register Provider operation failed"
    echo "Return Code: $rc"    
    exit $rc
fi

# Create the Vault
# Currently there is nothing in the output from this command that we require later so no need to parse the json
#   Required:
#    - Key Vault Name (default: SpinnakerVault)
#    - Resource Group Name from Step 1 
#    - Region (same as Resource Group)

# See if the keyvault already exists
echo "Checking for $DEFAULT_KEY_VAULT"
EXISTS=`azure keyvault list --json | jq '.[] | select(.name=="SpinnakerVault")'`

if [[ -z "$EXISTS" ]]; then 
    echo "Creating Key Vault \"$DEFAULT_KEY_VAULT\" in resource group \"$DEFAULT_RESOURCE_GROUP\""
    eval "azure keyvault create --vault-name $DEFAULT_KEY_VAULT --resource-group $DEFAULT_RESOURCE_GROUP --location $DEFAULT_REGION --json"
    rc=$?
    if [[ $rc -gt 0 ]]; then
        echo "Create KeyVault operation failed"
        exit $rc
    fi
fi

# Create the secrets in the vault
#   Required:
#    - vault name
#    - secret name
#    - secret value
SECRET_NAME='VMUsername'
echo "Create secret \"$SECRET_NAME\" in KeyVault \"$DEFAULT_KEY_VAULT\""
SUCCESS=`azure keyvault secret set --vault-name $DEFAULT_KEY_VAULT --secret-name $SECRET_NAME --value $UNAME --json | jq '.attributes.enabled'`
rc=$?
if [[ $rc -gt 0 ]]; then
    echo "Create Username Secret operation failed"
    if [[ "$SUCCESS" -ne "true" ]]; then
        echo "Enabled: $SUCCESS"
    fi
    exit $rc
fi

SECRET_NAME='VMPassword'
echo "Create secret \"$SECRET_NAME\" in KeyVault \"$DEFAULT_KEY_VAULT\""
SUCCESS=`azure keyvault secret set --vault-name $DEFAULT_KEY_VAULT --secret-name $SECRET_NAME --value $PWD --json | jq '.attributes.enabled'`
rc=$?
if [[ $rc -gt 0 ]]; then
    echo "Create Password Secret operation failed"
    if [[ "$SUCCESS" -ne "true" ]]; then
        echo "Enabled: $SUCCESS"
    fi
    exit $rc
fi

# Grant permissions to the Service Principal account to access the secrects
#   Required:
#    - vault name
#    - service principal ID
#    - permissions to grant to secret (default: "get")
if [[ -n "$APPID" ]]; then
    SPN_ID="$APPID"
else
    SPN_ID=`azure ad sp show $SPN | jq '.appId' | tr -d '"'`
fi

if [[ $DEBUG -gt 0 ]]; then
    echo "Service Principal ID: $SPN_ID"
fi

echo "Grant access to \"$SPN_ID\" to KeyVault secrets"
SUCCESS=`azure keyvault set-policy --vault-name $DEFAULT_KEY_VAULT --spn $SPN_ID --perms-to-secrets '["get"]'`
rc=$?
if [[ $rc -gt 0 ]]; then
    echo "Grant Access to Secret operation failed"        
    exit $rc
fi

echo "Key Vault setup complete"
exit
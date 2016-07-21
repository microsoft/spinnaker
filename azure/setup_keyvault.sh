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
    echo "Usage: setup_keyvault.sh -s \"<service_principal_name>\" -u \"<VM_username>\" -p \"<VM_Password>\" [-a <AppID>] -h"      
}

DEFAULT_RESOURCE_GROUP="SpinnakerDefault"
DEFAULT_KEY_VAULT="SpinnakerVault"
DEFAULT_REGION="eastus"

DEBUG=0
SPN=""
UNAME=""
PWD=""
APPID=""

function process_args() {
    # parse parameters    
    while [[ $# > 0 ]] 
    do
        local key=$1        
        shift
        case $key in
            -s|--spn)
                SPN="$1"
                shift
                ;;
            -u|--username)
                UNAME="$1"
                shift
                ;;
            -p|--password)
                PWD="$1"
                shift
                ;;
            -a|--appId)
                APPID="$1"
                shift                
                ;;
            -d|--debug)            
                DEBUG=1                      
                ;;
            -h|--help|-help)            
                usage
                exit
                ;;
            *)
                echo "ERROR: Unknown option: '$key'"
                usage
                exit 1
                ;;
        esac
    done    
    echo "DEBUG: $DEBUG"

    if [[ $DEBUG -gt 0 ]]; then
        echo "Service Principal Name: $SPN"
        echo "VM Username: $UNAME"
        echo "VM Password: $PWD"
        echo "App ID: $APPID"    
    fi

    if [[ -z "$UNAME" || -z "$PWD" ]]; then
        echo "You must supply a USERNAME AND PASSWORD to use as the default credentials for VM instances"
        usage
        exit 1
    fi

    if [[ -z "$SPN" && -z "$APPID" ]]; then
        echo "You must supply either the Service Principal Name or the Application ID"
        usage
        exit 1
    fi     
}

function verify_login() {
    # Query account information to see if the user is still logged in
    TENANT_ID=`azure account show --json | jq '.[].tenantId'`

    if [[ -z TENANT_ID ]]; then
        # if we can't get the account information then it's assumed we are not logged in
        echo "Unable to access account information. Ensure that you are logged in"
        exit $?
    fi
}

# Create the Resource Group if not exist
#   Required:
#    - Resource Group Name 
#    - Region (default: East-US)
function create_resource_group() {
    # see if the resource group already exists. If not, then create it
    local RESPONSE=`azure group show $DEFAULT_RESOURCE_GROUP --json`
    local RESOUCE_GROUP=""
    rc=$?
    if [[ $rc != 0 ]]; then
        local RESOURCE_GROUP=`echo $RESPONSE | jq '.name'`
    fi

    if [[ "$RESOUCE_GROUP" != "$DEFAULT_SPINNAKER_GROUP" ]]; then    
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
    else 
        echo "Using existing resource group $DEFAULT_RESOURCE_GROUP"
    fi
}

# Register the Azure KeyVault Provider
# The register command does not return any json 
function register_providers() {
    echo "Registering KeyVault provider"
    eval 'azure provider register Microsoft.KeyVault --json'
    rc=$?
    if [[ $rc -gt 0 ]]; then
        echo "Register Provider operation failed"
        echo "Return Code: $rc"    
        exit $rc
    fi
}

# Create the Vault
# Currently there is nothing in the output from this command that we require later so no need to parse the json
#   Required:
#    - Key Vault Name (default: SpinnakerVault)
#    - Resource Group Name from Step 1 
#    - Region (same as Resource Group)
function create_keyvault() {
# See if the keyvault already exists
    echo "Checking for $DEFAULT_KEY_VAULT"
    EXISTS=`azure keyvault list --json | jq '.[] | select(.name=="SpinnakerVault")'`

    if [[ -z "$EXISTS" ]]; then 
        echo "Creating Key Vault \"$DEFAULT_KEY_VAULT\" in resource group \"$DEFAULT_RESOURCE_GROUP\""
        local TEMP=`azure keyvault create --vault-name $DEFAULT_KEY_VAULT --resource-group $DEFAULT_RESOURCE_GROUP --location $DEFAULT_REGION --json`
        rc=$?
        if [[ $rc -gt 0 ]]; then
            echo "Create KeyVault operation failed"
            exit $rc
        fi
    fi
}

# Create the secrets in the vault
#   Required:
#    - vault name
#    - secret name
#    - secret value
function add_secrets_to_vault() {
    echo "Inserting secrets into KeyVault"

    # Verify the KeyVault has been setup
    local rc=-1
    echo "Waiting for vault $DEFAULT_KEY_VAULT to be ready...."
    while [[ $rc != 0 ]]; do
        KEYVAULT=`azure keyvault show $DEFAULT_KEY_VAULT --json | jq '.name'`
        rc=$?
    done        
    
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
}

# Grant permissions to the Service Principal account to access the secrects
#   Required:
#    - vault name
#    - service principal ID
#    - permissions to grant to secret (default: "get")
function set_secrets_permissions() {
    if [[ -n "$APPID" ]]; then
        SPN_ID="$APPID"
    else
        local RESPONSE=`azure ad sp show --search "$SPN" --json`        
        SPN_ID=`echo $RESPONSE | jq '.[].appId' | tr -d '"'`
    fi

    if [[ $DEBUG -gt 0 ]]; then
        echo "Service Principal ID: $SPN_ID"
    fi

    echo "Grant access to \"$SPN_ID\" to KeyVault secrets"
    SUCCESS=`azure keyvault set-policy --vault-name $DEFAULT_KEY_VAULT --spn $SPN_ID --enabled-for-deployment true --perms-to-secrets '["get"]'`
    rc=$?
    if [[ $rc -gt 0 ]]; then
        echo "Grant Access to Secret operation failed"        
        exit $rc
    fi    
}

process_args "$@"
verify_login
create_resource_group
register_providers
create_keyvault
add_secrets_to_vault
set_secrets_permissions

echo "Key Vault setup complete"

exit
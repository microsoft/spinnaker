#!/bin/bash
set -e
set -o pipefail

DEBUG=0

#Query account information
RESPONSE=`azure account show --json`

#capture tenant id and subscription id
TENANT_ID=`echo $RESPONSE | jq '.[].tenantId'`
SUBSCRIPTION_ID=`echo $RESPONSE | jq '.[].id' | tr -d '"'`

while getopts ":a:h:i:p:d" opt; do
    case "${opt}" in
        a)
            DEFAULT_APP_NAME=${OPTARG}
            ;;
        h)
            DEFAULT_HOMEPAGE=${OPTARG}
            ;;
        i) 
            DEFAULT_IDENTIFIER_URIS=${OPTARG}
            ;;
        p)
            DEFAULT_PASSWORD=${OPTARG}
            ;;
        d)
            DEBUG=1
            ;;
        \?)
            usage
            exit 1
            ;;
    esac
done

#Read in parameters for Service Principal creation
if [[ -z "$DEFAULT_APP_NAME" ]]; then
    DEFAULT_APP_NAME="ExampleApp"
    read -e -p "Specify app name: " -i "$DEFAULT_APP_NAME" APP_NAME
fi

if [[ -z "$DEFAULT_HOMEPAGE" ]]; then
    DEFAULT_HOMEPAGE="http://www.contosorg.org"
    read -e -p "Specify homepage: " -i "$DEFAULT_HOMEPAGE" HOMEPAGE
fi

if [[ -z "$DEFAULT_IDENTIFIER_URIS" ]]; then 
    DEFAULT_IDENTIFIER_URIS="https://www.contosorg.org/example"
    read -e -p "Specify identifier-uris: " -i "$DEFAULT_IDENTIFIER_URIS" IDENTIFIER_URIS
fi

if [[ -z "$DEFAULT_PASSWORD" ]]; then
    DEFAULT_PASSWORD="Thund3rd0m3!"
    read -e -p "Specify password: " -i "$DEFAULT_PASSWORD" PASSWORD
fi

#DEBUG prints
if [[ $DEBUG -gt 0 ]]; then
    echo 'App Name: '$APP_NAME
    echo '$HOMEPAGE: '$HOMEPAGE
    echo 'Identifier URIs: '$IDENTIFIER_URIS
    echo 'Password: '$PASSWORD
fi

#create app in active directory for subscription
echo "Creating application $APP_NAME..."
RESPONSE=`azure ad app create --name "$APP_NAME" --home-page "$HOMEPAGE" --identifier-uris "$IDENTIFIER_URIS" --password "$PASSWORD" --json`

rc=$?; if [[ $rc != 0 ]]; then exit $rc; fi

#Capture appId as client id and remove quotes
CLIENT_ID=`echo $RESPONSE | jq '.appId' | tr -d '"'`

rc=$?; if [[ $rc != 0 ]]; then exit $rc; fi

echo "Creating the service principal..."
RESPONSE2=`azure ad sp create --applicationId "$CLIENT_ID" --json`

if [[ $DEBUG -gt 0 ]]; then
    echo $RESPONSE2
    echo 
fi

rc=$?; if [[ $rc != 0 ]]; then exit $rc; fi

echo "Set role assignment for Service Principal..."
OBJECT_ID=`echo $RESPONSE2 | jq '.objectId' | tr -d '"'`

if [[ $DEBUG -gt 0 ]]; then
    echo "Service Principal ID:" "$OBJECT_ID"
fi

RESPONSE3=`azure role assignment create --objectId "$OBJECT_ID" -o Contributor -c /subscriptions/"$SUBSCRIPTION_ID"/ --json`

if [[ $DEBUG -gt 0 ]]; then
    echo "Role assignment response: $RESPONSE3"
fi

echo "Setting up Keyvault...."
if [[ $DEBUG -gt 0 ]]; then
    KV_CMD=`./setup_keyvault.sh -a "$CLIENT_ID" -d`
else
    KV_CMD=`./setup_keyvault.sh -a "$CLIENT_ID"`
fi

echo $KV_CMD

echo 'Tenant ID: '$TENANT_ID
echo 'Subscription ID: '$SUBSCRIPTION_ID
echo 'Client ID: '$CLIENT_ID
echo 'Object ID:'$OBJECT_ID
echo 'Display name: '$APP_NAME

echo "Azure setup complete"
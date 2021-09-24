#!/bin/bash

# Script to download then re-deploy all apps in an environment. Use case is when a cluster needs to be re-made.
# Alternatively from using the Anypoint platform APIs (uses v1 APIs) user to get the list of apps and download them the user
# can create a file or use a backup file from a previous run but must have the app jar files on hand.
# format for file would be:
# appID appName fileName
# 12345 test-api test-api-1.0.0-mule-application.jar
# The new cluster ID will automatically be fetched from the specified environment. 
# If there are multiple clusters in the environment then the first one is used.

############################
# Global Variables
############################
list=""
attemptCount=1

############################
# Functions
############################
function checkUserInput () {
    if [ "$1" == "q" ]
    then
        # exit
        echo
        echo "Exiting...."
        exit 0
    fi
}

function userCheckList () {
    # Print details retrieved for user verification
    echo
    echo "App Details retrieved from $sourceData"
    echo "$list"
    echo
    read  -n 1 -p "Does this look correct? Hit any key to proceed, q to quit:  " proceedEntry
    checkUserInput "$proceedEntry"
    echo
}

function createBackupFile () {
    echo
    if [ "$1" == "y" ]
    then
        # Save backup of the app list to a file
        echo "$list" > appDataList.txt
        echo "Created backup file 'appDataList.txt' in current directory"
    else
        echo "No backup will be created"
    fi
}

function printAppNames () {
    echo "Details received for the following apps"
    export DW_DEFAULT_INPUT_MIMETYPE=text/plain
    echo "$1" | dw "
    output text/plain
    ---
    ((payload splitBy \"\\n\") map ($ splitBy  \" \")[2]) joinBy \"\\n\"
    "
}

function checkClusterId () {
    if [[ "$1" =~ [0-9]+ ]]
    then
        # Expect the cluster ID to be all digits
        echo "New cluster ID: $1"
    else
        # Otherwise must have received an error message so print and exit
        echo "Received the following error response:"
        echo "$1"
        echo "Exiting..."
        exit 0
    fi
}

function getAppDataFromPlatform () {
    # Get the current list of apps names, ids, filenames from ARM
    list=$(
    curl --progress-bar --location --request GET 'https://anypoint.mulesoft.com/hybrid/api/v1/applications' --header "X-ANYPNT-ENV-ID: $ENV" --header "X-ANYPNT-ORG-ID: $ORG" --header "Authorization: Bearer $authToken" | 
    dw "
    output text/plain
    ---
    if(!isEmpty(payload.data)) 
        (((payload.data[?($.started)] orderBy ($.name) map {
            v:(
                $.id  ++ \" \" ++ 
                $.name ++ \" \" ++ 
                ($.serverArtifacts orderBy ($.timeUpdated))[-1].artifact.fileName
            )
        }) map $.v) default []) joinBy  \"\\n\"
    else if (!isEmpty(payload.message)) 
        payload.message
    else 
        payload
    ")

    # If there were no results then exit
    if [ -z "$list" ]
    then
        echo "There were no apps returned for that combination of Environment, Organization, Auth token... Exiting."
        exit 1
    fi

    # Optionally create a backup file
    echo
    read  -n 1 -p "Create backup of the app list? y/n:  " createBackup
    createBackupFile "$createBackup"

    # Ask to proceed downloading apps
    echo
    read  -n 1 -p "Hit any key to proceed with downloading all apps to current directory, q to quit:  " proceedEntry
    checkUserInput "$proceedEntry"

    # Get apps from ARM and download to current directory
    echo "$list" | while read a b c
    do 
        echo "Starting download for: $b";
        curl --progress-bar --location --request GET "https://anypoint.mulesoft.com/hybrid/api/v1/applications/$a/artifact" --header "X-ANYPNT-ENV-ID: $ENV" --header "X-ANYPNT-ORG-ID: $ORG" --header "Authorization: Bearer $authToken" --output $c;
        echo "download complete for: $b"
    done
    echo "All apps downloaded"
}

function getAppDataFromFile () {
    echo -n "Enter the filename (must be txt file, default will be appDataList.txt): "
    read appDataFile
    appDataFile="${appDataFile:=appDataList.txt}"
    list=$(<$appDataFile)
    if [ -z "$list" ]
    then
        # No data found in that file so exit
        echo "Problem with that file... Exiting."
        exit 1
    fi
    
    # Allow user to check the app list for accuracy
    userCheckList
}

############################
# Main
############################

# Gather input for process
echo -n "Enter the Environment ID: "
read environment
ENV="${environment}"
echo "Environment: $ENV"

echo -n "Enter the Organization ID: "
read organization
ORG="${organization}"
echo "Organization: $ORG"

while true 
do read -p  "Enter an Auth Token: " authToken
    if [[ ${authToken//-/} =~ ^[[:xdigit:]]{32}$ ]]
    then
        echo "Auth Token: $authToken"
        break
    else
        # Invalid token entered, re-prompt user
        echo "Please enter a valid Auth Token. Attempt $attemptCount of 3"
        if [[ $attemptCount -gt 3 ]]
        then
            echo "No valid auth token provided after $attemptCount attempts... Exiting"
            exit 1
        else
            ((attemptCount++))
            continue
        fi
    fi
done

read  -n 1 -p "Read app details from a file or platform f/p?  " readInfoFromFile
echo
if [ "$readInfoFromFile" == "p" ]
then
    # Get app data from platform
    sourceData="platform"
    getAppDataFromPlatform
elif [ "$readInfoFromFile" == "f" ]
then
    # Get app data from file
    sourceData="file"
    getAppDataFromFile
else
    echo "No valid option was selected. Exiting..."
    exit 1
fi

# User needs to remove cluster (which removes all apps from every server) and then re-create it before proceeding
read  -n 1 -p "Next remove the cluster and re-create it. Once all servers are restarted and added to the new cluster, hit any key to continue or q to quit:  " enteredKey
checkUserInput "$enteredKey"

# Get new cluster ID
echo "Fetching new cluster ID (will default to first one retrieved if there are multiple)"
clusterId=$(curl --location --request GET 'https://anypoint.mulesoft.com/hybrid/api/v1/clusters' --header "X-ANYPNT-ENV-ID: $ENV" --header "X-ANYPNT-ORG-ID: $ORG" --header "Authorization: Bearer $authToken" | dw "output text/json --- if(!isEmpty(payload.data)) payload.data[0].id else payload")
checkClusterId "$clusterId"

# Deploy Apps to new Cluster
echo "$list" | while read a b c
do
    echo
    echo "starting upload for: $b";
    curl --progress-bar --location --output /dev/null --request POST 'https://anypoint.mulesoft.com/hybrid/api/v1/applications' --header "X-ANYPNT-ENV-ID: $ENV" --header "X-ANYPNT-ORG-ID: $ORG" --header "Authorization: Bearer $authToken" --form "file=@\"$c\"" --form "artifactName=\"$b\"" --form "targetId=\"$clusterId\"" 2>&1 | cat
    echo "upload complete for: $b"
done

echo "All apps uploaded"


exit 0
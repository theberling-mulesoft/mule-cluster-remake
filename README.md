# mule-cluster-remake

Script to download then re-deploy all apps in an environment. Use case is when a cluster needs to be re-made.
Alternatively from using the Anypoint platform APIs (uses v1 APIs) user to get the list of apps and download them the user can create a file or use a backup file from a previous run but must have the app jar files on hand.

Format for file would be:
```
appID appName fileName
12345 test-api test-api-1.0.0-mule-application.jar
```

The new cluster ID will automatically be fetched from the specified environment. If there are multiple clusters in the environment then the first one is used.

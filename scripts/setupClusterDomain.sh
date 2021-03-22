#!/bin/bash

#Function to output message to StdErr
function echo_stderr ()
{
    echo "$@" >&2
}

#Function to display usage message
function usage()
{
  echo_stderr "./setupClusterDomain.sh <wlsDomainName> <wlsUserName> <wlsPassword> <wlsServerName> <wlsAdminHost> <storageAccountName> <storageAccountKey> <mountpointPath> <enableHTTPAdminListenPort> <isCustomSSLEnabled> [<customIdentityKeyStoreData> <customIdentityKeyStorePassPhrase> <customIdentityKeyStoreType> <customTrustKeyStoreData> <customTrustKeyStorePassPhrase> <customTrustKeyStoreType> <serverPrivateKeyAlias <serverPrivateKeyPassPhrase>]"
}

function installUtilities()
{
    echo "Installing zip unzip wget vnc-server rng-tools cifs-utils"
    sudo yum install -y zip unzip wget vnc-server rng-tools cifs-utils

    #Setting up rngd utils
    attempt=1
    while [[ $attempt -lt 4 ]]
    do
       echo "Starting rngd service attempt $attempt"
       sudo systemctl start rngd
       attempt=`expr $attempt + 1`
       sudo systemctl status rngd | grep running
       if [[ $? == 0 ]];
       then
          echo "rngd utility service started successfully"
          break
       fi
       sleep 1m
    done
}

function validateInput()
{
    if [ -z "$wlsDomainName" ];
    then
        echo_stderr "wlsDomainName is required. "
    fi

    if [[ -z "$wlsUserName" || -z "$wlsPassword" ]]
    then
        echo_stderr "wlsUserName or wlsPassword is required. "
        exit 1
    fi

    if [ -z "$wlsServerName" ];
    then
        echo_stderr "wlsServerName is required. "
    fi

    if [ -z "$wlsAdminHost" ];
    then
        echo_stderr "wlsAdminHost is required. "
    fi

    if [ -z "$oracleHome" ]; 
    then 
        echo_stderr "oracleHome is required. " 
        exit 1 
    fi

    if [ -z "$storageAccountName" ];
    then 
        echo_stderr "storageAccountName is required. "
        exit 1
    fi
    
    if [ -z "$storageAccountKey" ];
    then 
        echo_stderr "storageAccountKey is required. "
        exit 1
    fi
    
    if [ -z "$mountpointPath" ];
    then 
        echo_stderr "mountpointPath is required. "
        exit 1
    fi

    if [ "${isCustomSSLEnabled}" != "true" ];
    then
        echo_stderr "Custom SSL value is not provided. Defaulting to false"
        isCustomSSLEnabled="false"
    else
        if   [ -z "$customIdentityKeyStoreData" ]    || [ -z "$customIdentityKeyStorePassPhrase" ] ||
             [ -z "$customIdentityKeyStoreType" ]    || [ -z "$customTrustKeyStoreData" ] ||
             [ -z "$customTrustKeyStorePassPhrase" ] || [ -z "$customTrustKeyStoreType" ] ||
             [ -z "$serverPrivateKeyAlias" ]         || [ -z "$serverPrivateKeyPassPhrase" ];
        then
            echo "One of the required values for enabling Custom SSL \
            (CustomKeyIdentityKeyStoreData,CustomKeyIdentityKeyStorePassPhrase,CustomKeyIdentityKeyStoreType,CustomKeyTrustKeyStoreData,CustomKeyTrustKeyStorePassPhrase,CustomKeyTrustKeyStoreType) \
            has not been provided."
            exit 1
        fi
    fi
}

#Function to cleanup all temporary files
function cleanup()
{
    echo "Cleaning up temporary files..."

    rm -rf $DOMAIN_PATH/admin-domain.yaml
    rm -rf $DOMAIN_PATH/managed-domain.yaml
    rm -rf $DOMAIN_PATH/weblogic-deploy.zip
    rm -rf $DOMAIN_PATH/weblogic-deploy
    rm -rf $DOMAIN_PATH/deploy-app.yaml
    rm -rf $DOMAIN_PATH/shoppingcart.zip
    rm -rf $DOMAIN_PATH/*.py
    echo "Cleanup completed."
}

#Creates weblogic deployment model for cluster domain admin setup
function create_admin_model()
{
    echo "Creating admin domain model"

cat /dev/null > $DOMAIN_PATH/admin-domain.yaml

    cat <<EOF >$DOMAIN_PATH/admin-domain.yaml
domainInfo:
   AdminUserName: "$wlsUserName"
   AdminPassword: "$wlsPassword"
   ServerStartMode: prod
topology:
   Name: "$wlsDomainName"
   AdminServerName: admin
   Machine:
     '$nmHost':
         NodeManager:
             ListenAddress: "$nmHost"
             ListenPort: $nmPort
             NMType : ssl
   Cluster:
        '$wlsClusterName':
             MigrationBasis: 'consensus'
   Server:
        '$wlsServerName':
            ListenPort: $wlsAdminPort
            NetworkAccessPoint:
                'adminT3Channel':
                    ListenAddress: '$wlsAdminHost'
                    ListenPort: $wlsAdminT3ChannelPort
                    Protocol: t3
                    Enabled: true
            ListenPortEnabled: ${isHTTPAdminListenPortEnabled}
            RestartDelaySeconds: 10
EOF

        if [ "${isCustomSSLEnabled}" == "true" ];
        then
cat <<EOF>>$DOMAIN_PATH/admin-domain.yaml
            KeyStores: 'CustomIdentityAndCustomTrust'
            CustomIdentityKeyStoreFileName: "$customIdentityKeyStoreFileName"
            CustomIdentityKeyStoreType: "$customIdentityKeyStoreType"
            CustomIdentityKeyStorePassPhraseEncrypted: "$customIdentityKeyStorePassPhrase"
            CustomTrustKeyStoreFileName: "$customTrustKeyStoreFileName"
            CustomTrustKeyStoreType: "$customTrustKeyStoreType"
            CustomTrustKeyStorePassPhraseEncrypted: "$customTrustKeyStorePassPhrase"
EOF
        fi

cat <<EOF>>$DOMAIN_PATH/admin-domain.yaml
            SSL:
               ListenPort: $wlsSSLAdminPort
               Enabled: true
               HostnameVerificationIgnored: true
               HostnameVerifier: 'None'
EOF

        if [ "${isCustomSSLEnabled}" == "true" ];
        then
cat <<EOF>>$DOMAIN_PATH/admin-domain.yaml
               ServerPrivateKeyAlias: "$serverPrivateKeyAlias"
               ServerPrivateKeyPassPhraseEncrypted: "$serverPrivateKeyPassPhrase"
EOF
        fi

cat <<EOF>>$DOMAIN_PATH/admin-domain.yaml
   SecurityConfiguration:
       NodeManagerUsername: "$wlsUserName"
       NodeManagerPasswordEncrypted: "$wlsPassword"
EOF
}

#Creates weblogic deployment model for cluster domain managed server
function create_managed_model()
{
    echo "Creating managed domain model"
    cat <<EOF >$DOMAIN_PATH/managed-domain.yaml
domainInfo:
   AdminUserName: "$wlsUserName"
   AdminPassword: "$wlsPassword"
   ServerStartMode: prod
topology:
   Name: "$wlsDomainName"
   Machine:
     '$nmHost':
         NodeManager:
             ListenAddress: "$nmHost"
             ListenPort: $nmPort
             NMType : ssl
   Cluster:
        '$wlsClusterName':
             MigrationBasis: 'consensus'
   Server:
        '$wlsServerName' :
           ListenPort: $wlsManagedPort
           Notes: "$wlsServerName managed server"
           Cluster: "$wlsClusterName"
           Machine: "$nmHost"
EOF
    
if [ "${isCustomSSLEnabled}" == "true" ];
        then
cat <<EOF>>$DOMAIN_PATH/managed-domain.yaml
           KeyStores: 'CustomIdentityAndCustomTrust'
           CustomIdentityKeyStoreFileName: "$customIdentityKeyStoreFileName"
           CustomIdentityKeyStoreType: "$customIdentityKeyStoreType"
           CustomIdentityKeyStorePassPhraseEncrypted: "$customIdentityKeyStorePassPhrase"
           CustomTrustKeyStoreFileName: "$customTrustKeyStoreFileName"
           CustomTrustKeyStoreType: "$customTrustKeyStoreType"
           CustomTrustKeyStorePassPhraseEncrypted: "$customTrustKeyStorePassPhrase"
EOF
        fi

cat <<EOF>>$DOMAIN_PATH/managed-domain.yaml
           SSL:
                HostnameVerificationIgnored: true
                HostnameVerifier: 'None'
EOF

        if [ "${isCustomSSLEnabled}" == "true" ];
        then
cat <<EOF>>$DOMAIN_PATH/managed-domain.yaml
                ServerPrivateKeyAlias: "$serverPrivateKeyAlias"
                ServerPrivateKeyPassPhraseEncrypted: "$serverPrivateKeyPassPhrase"
EOF
        fi

    cat <<EOF >>$DOMAIN_PATH/managed-domain.yaml
   SecurityConfiguration:
       NodeManagerUsername: "$wlsUserName"
       NodeManagerPasswordEncrypted: "$wlsPassword"
EOF
}

#This function to add machine for a given managed server
function create_machine_model()
{
    echo "Creating machine name model for managed server $wlsServerName"
    cat <<EOF >$DOMAIN_PATH/add-machine.py
connect('$wlsUserName','$wlsPassword','$adminWlstURL')
edit("$wlsServerName")
startEdit()
cd('/')
cmo.createMachine('$nmHost')
cd('/Machines/$nmHost/NodeManager/$nmHost')
cmo.setListenPort(int($nmPort))
cmo.setListenAddress('$nmHost')
cmo.setNMType('ssl')
save()
resolve()
activate()
destroyEditSession("$wlsServerName")
disconnect()
EOF
}

#This function to add managed serverto admin node
function create_ms_server_model()
{
    echo "Creating managed server $wlsServerName model"
    cat <<EOF >$DOMAIN_PATH/add-server.py

isCustomSSLEnabled='${isCustomSSLEnabled}'
connect('$wlsUserName','$wlsPassword','$adminWlstURL')
edit("$wlsServerName")
startEdit()
cd('/')
cmo.createServer('$wlsServerName')
cd('/Servers/$wlsServerName')
cmo.setMachine(getMBean('/Machines/$nmHost'))
cmo.setCluster(getMBean('/Clusters/$wlsClusterName'))
cmo.setListenAddress('$nmHost')
cmo.setListenPort(int($wlsManagedPort))
cmo.setListenPortEnabled(true)

if isCustomSSLEnabled == 'true' :
    cmo.setKeyStores('CustomIdentityAndCustomTrust')
    cmo.setCustomIdentityKeyStoreFileName('$customIdentityKeyStoreFileName')
    cmo.setCustomIdentityKeyStoreType('$customIdentityKeyStoreType')
    set('CustomIdentityKeyStorePassPhrase', '$customIdentityKeyStorePassPhrase')
    cmo.setCustomTrustKeyStoreFileName('$customTrustKeyStoreFileName')
    cmo.setCustomTrustKeyStoreType('$customTrustKeyStoreType')
    set('CustomTrustKeyStorePassPhrase', '$customTrustKeyStorePassPhrase')

cd('/Servers/$wlsServerName/SSL/$wlsServerName')
cmo.setServerPrivateKeyAlias('$serverPrivateKeyAlias')
set('ServerPrivateKeyPassPhrase', '$serverPrivateKeyPassPhrase')
cmo.setHostnameVerificationIgnored(true)

cd('/Servers/$wlsServerName//ServerStart/$wlsServerName')
arguments = '-Dweblogic.Name=$wlsServerName  -Dweblogic.management.server=${SERVER_START_URL} -Dweblogic.security.SSL.ignoreHostnameVerification=true'
cmo.setArguments(arguments)
save()
resolve()
activate()
destroyEditSession("$wlsServerName")
nmEnroll('$DOMAIN_PATH/$wlsDomainName','$DOMAIN_PATH/$wlsDomainName/nodemanager')
nmGenBootStartupProps('$wlsServerName')
disconnect()
EOF
}

#Function to create Admin Only Domain
function create_adminSetup()
{
    echo "Creating Admin Setup"
    echo "Creating domain path $DOMAIN_PATH"
    echo "Downloading weblogic-deploy-tool"
 
    sudo mkdir -p $DOMAIN_PATH 
    sudo rm -rf $DOMAIN_PATH/*

    cd $DOMAIN_PATH
    wget -q $WEBLOGIC_DEPLOY_TOOL
    if [[ $? != 0 ]]; then
       echo "Error : Downloading weblogic-deploy-tool failed"
       exit 1
    fi
    sudo unzip -o weblogic-deploy.zip -d $DOMAIN_PATH
    storeCustomSSLCerts
    create_admin_model
    sudo chown -R $username:$groupname $DOMAIN_PATH
    runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; $DOMAIN_PATH/weblogic-deploy/bin/createDomain.sh -oracle_home $oracleHome -domain_parent $DOMAIN_PATH  -domain_type WLS -model_file $DOMAIN_PATH/admin-domain.yaml"
    if [[ $? != 0 ]]; then
       echo "Error : Admin setup failed"
       exit 1
    fi

    # For issue https://github.com/wls-eng/arm-oraclelinux-wls/issues/89
    copySerializedSystemIniFileToShare
}

#Function to setup admin boot properties
function admin_boot_setup()
{
 echo "Creating admin boot properties"
 #Create the boot.properties directory
 mkdir -p "$DOMAIN_PATH/$wlsDomainName/servers/admin/security"
 echo "username=$wlsUserName" > "$DOMAIN_PATH/$wlsDomainName/servers/admin/security/boot.properties"
 echo "password=$wlsPassword" >> "$DOMAIN_PATH/$wlsDomainName/servers/admin/security/boot.properties"
 sudo chown -R $username:$groupname $DOMAIN_PATH/$wlsDomainName/servers
 }

#This function to wait for admin server
function wait_for_admin()
{
 #wait for admin to start
count=1
export CHECK_URL="http://$wlsAdminURL/weblogic/ready"
status=`curl --insecure -ILs $CHECK_URL | tac | grep -m1 HTTP/1.1 | awk {'print $2'}`
echo "Waiting for admin server to start"
while [[ "$status" != "200" ]]
do
  echo "."
  count=$((count+1))
  if [ $count -le 30 ];
  then
      sleep 1m
  else
     echo "Error : Maximum attempts exceeded while starting admin server"
     exit 1
  fi
  status=`curl --insecure -ILs $CHECK_URL | tac | grep -m1 HTTP/1.1 | awk {'print $2'}`
  if [ "$status" == "200" ];
  then
     echo "Admin Server started succesfully..."
     break
  fi
done
}

# Create systemctl service for nodemanager
function create_nodemanager_service()
{
 echo "Setting CrashRecoveryEnabled true at $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties"
 sed -i.bak -e 's/CrashRecoveryEnabled=false/CrashRecoveryEnabled=true/g'  $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
 sed -i.bak -e 's/ListenAddress=.*/ListenAddress=/g'  $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties

if [ "${isCustomSSLEnabled}" == "true" ];
then
    echo "KeyStores=CustomIdentityAndCustomTrust" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomIdentityKeystoreType=${customIdentityKeyStoreType}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomIdentityKeyStoreFileName=${customIdentityKeyStoreFileName}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomIdentityKeyStorePassPhrase=${customIdentityKeyStorePassPhrase}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomIdentityAlias=${serverPrivateKeyAlias}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomIdentityPrivateKeyPassPhrase=${serverPrivateKeyPassPhrase}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomTrustKeystoreType=${customTrustKeyStoreType}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomTrustKeyStoreFileName=${customTrustKeyStoreFileName}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomTrustKeyStorePassPhrase=${customTrustKeyStorePassPhrase}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
fi

 if [ $? != 0 ];
 then
   echo "Warning : Failed in setting option CrashRecoveryEnabled=true. Continuing without the option."
   mv $DOMAIN_PATH/nodemanager/nodemanager.properties.bak $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
 fi
 sudo chown -R $username:$groupname $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties*
 echo "Creating NodeManager service"
 # Added waiting for network-online service and restart service 
 cat <<EOF >/etc/systemd/system/wls_nodemanager.service
 [Unit]
Description=WebLogic nodemanager service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Note that the following three parameters should be changed to the correct paths
# on your own system
WorkingDirectory="$DOMAIN_PATH/$wlsDomainName"
ExecStart="$DOMAIN_PATH/$wlsDomainName/bin/startNodeManager.sh"
ExecStop="$DOMAIN_PATH/$wlsDomainName/bin/stopNodeManager.sh"
User=oracle
Group=oracle
KillMode=process
LimitNOFILE=65535
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

# This function to create adminserver service
function create_adminserver_service()
{
# Added waiting for network-online service and restart service   
 echo "Creating admin server service"
 cat <<EOF >/etc/systemd/system/wls_admin.service
[Unit]
Description=WebLogic Adminserver service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory="$DOMAIN_PATH/$wlsDomainName"
ExecStart="${startWebLogicScript}"
ExecStop="${stopWebLogicScript}"
User=oracle
Group=oracle
KillMode=process
LimitNOFILE=65535
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

#This function to start managed server
function start_managed()
{
    echo "Starting managed server $wlsServerName"
    cat <<EOF >$DOMAIN_PATH/start-server.py
connect('$wlsUserName','$wlsPassword','$adminWlstURL')
try:
   start('$wlsServerName', 'Server')
except:
   print "Failed starting managed server $wlsServerName"
   dumpStack()
disconnect()
EOF
sudo chown -R $username:$groupname $DOMAIN_PATH
runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; java $WLST_ARGS weblogic.WLST $DOMAIN_PATH/start-server.py"
if [[ $? != 0 ]]; then
  echo "Error : Failed in starting managed server $wlsServerName"
  exit 1
fi
}

# Create managed server setup
function create_managedSetup(){
    echo "Creating Managed Server Setup"
    echo "Downloading weblogic-deploy-tool"

    DOMAIN_PATH="/u01/domains" 
    sudo mkdir -p $DOMAIN_PATH 
    sudo rm -rf $DOMAIN_PATH/*

    cd $DOMAIN_PATH
    wget -q $WEBLOGIC_DEPLOY_TOOL
    if [[ $? != 0 ]]; then
       echo "Error : Downloading weblogic-deploy-tool failed"
       exit 1
    fi

    storeCustomSSLCerts

    sudo unzip -o weblogic-deploy.zip -d $DOMAIN_PATH
    echo "Creating managed server model files"
    create_managed_model
    create_machine_model
    create_ms_server_model
    
    echo "Completed managed server model files"
    sudo chown -R $username:$groupname $DOMAIN_PATH
    runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; $DOMAIN_PATH/weblogic-deploy/bin/createDomain.sh -oracle_home $oracleHome -domain_parent $DOMAIN_PATH  -domain_type WLS -model_file $DOMAIN_PATH/managed-domain.yaml"
    if [[ $? != 0 ]]; then
       echo "Error : Managed setup failed"
       exit 1
    fi
    wait_for_admin
    
    # For issue https://github.com/wls-eng/arm-oraclelinux-wls/issues/89
    getSerializedSystemIniFileFromShare
    
    echo "Adding machine to managed server $wlsServerName"
    runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; java $WLST_ARGS weblogic.WLST $DOMAIN_PATH/add-machine.py"
    if [[ $? != 0 ]]; then
         echo "Error : Adding machine for managed server $wlsServerName failed"
         exit 1
    fi
    echo "Adding managed server $wlsServerName"
    runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; java $WLST_ARGS weblogic.WLST $DOMAIN_PATH/add-server.py"
    if [[ $? != 0 ]]; then
         echo "Error : Adding server $wlsServerName failed"
         exit 1
    fi
}

function enabledAndStartNodeManagerService()
{
  sudo systemctl enable wls_nodemanager
  sudo systemctl daemon-reload

  attempt=1
  while [[ $attempt -lt 6 ]]
  do
     echo "Starting nodemanager service attempt $attempt"
     sudo systemctl start wls_nodemanager
     sleep 1m
     attempt=`expr $attempt + 1`
     sudo systemctl status wls_nodemanager | grep running
     if [[ $? == 0 ]];
     then
         echo "wls_nodemanager service started successfully"
	 break
     fi
     sleep 3m
 done
}

function enableAndStartAdminServerService()
{
  sudo systemctl enable wls_admin
  sudo systemctl daemon-reload
  echo "Starting admin server service"
  sudo systemctl start wls_admin

}

function updateNetworkRules()
{
    # for Oracle Linux 7.3, 7.4, iptable is not running.
    if [ -z `command -v firewall-cmd` ]; then
        return 0
    fi
    
    # for Oracle Linux 7.6, open weblogic ports
    tag=$1
    if [ ${tag} == 'admin' ]; then
        echo "update network rules for admin server"
        sudo firewall-cmd --zone=public --add-port=$wlsAdminPort/tcp
        sudo firewall-cmd --zone=public --add-port=$wlsSSLAdminPort/tcp
        sudo firewall-cmd --zone=public --add-port=$wlsManagedPort/tcp
        sudo firewall-cmd --zone=public --add-port=$wlsAdminT3ChannelPort/tcp
        sudo firewall-cmd --zone=public --add-port=$nmPort/tcp
    else
        echo "update network rules for managed server"
        sudo firewall-cmd --zone=public --add-port=$wlsManagedPort/tcp
        sudo firewall-cmd --zone=public --add-port=$nmPort/tcp

        # open ports for coherence
        sudo firewall-cmd --zone=public --add-port=$coherenceListenPort/tcp
        sudo firewall-cmd --zone=public --add-port=$coherenceListenPort/udp
        sudo firewall-cmd --zone=public --add-port=$coherenceLocalport-$coherenceLocalportAdjust/tcp
        sudo firewall-cmd --zone=public --add-port=$coherenceLocalport-$coherenceLocalportAdjust/udp
        sudo firewall-cmd --zone=public --add-port=7/tcp
    fi

    sudo firewall-cmd --runtime-to-permanent
    sudo systemctl restart firewalld
}

# Mount the Azure file share on all VMs created
function mountFileShare()
{
  echo "Creating mount point"
  echo "Mount point: $mountpointPath"
  sudo mkdir -p $mountpointPath
  if [ ! -d "/etc/smbcredentials" ]; then
    sudo mkdir /etc/smbcredentials
  fi
  if [ ! -f "/etc/smbcredentials/${storageAccountName}.cred" ]; then
    echo "Crearing smbcredentials"
    echo "username=$storageAccountName >> /etc/smbcredentials/${storageAccountName}.cred"
    echo "password=$storageAccountKey >> /etc/smbcredentials/${storageAccountName}.cred"
    sudo bash -c "echo "username=$storageAccountName" >> /etc/smbcredentials/${storageAccountName}.cred"
    sudo bash -c "echo "password=$storageAccountKey" >> /etc/smbcredentials/${storageAccountName}.cred"
  fi
  echo "chmod 600 /etc/smbcredentials/${storageAccountName}.cred"
  sudo chmod 600 /etc/smbcredentials/${storageAccountName}.cred
  echo "//${storageAccountName}.file.core.windows.net/wlsshare $mountpointPath cifs nofail,vers=2.1,credentials=/etc/smbcredentials/${storageAccountName}.cred ,dir_mode=0777,file_mode=0777,serverino"
  sudo bash -c "echo \"//${storageAccountName}.file.core.windows.net/wlsshare $mountpointPath cifs nofail,vers=2.1,credentials=/etc/smbcredentials/${storageAccountName}.cred ,dir_mode=0777,file_mode=0777,serverino\" >> /etc/fstab"
  echo "mount -t cifs //${storageAccountName}.file.core.windows.net/wlsshare $mountpointPath -o vers=2.1,credentials=/etc/smbcredentials/${storageAccountName}.cred,dir_mode=0777,file_mode=0777,serverino"
  sudo mount -t cifs //${storageAccountName}.file.core.windows.net/wlsshare $mountpointPath -o vers=2.1,credentials=/etc/smbcredentials/${storageAccountName}.cred,dir_mode=0777,file_mode=0777,serverino
  if [[ $? != 0 ]];
  then
         echo "Failed to mount //${storageAccountName}.file.core.windows.net/wlsshare $mountpointPath"
	 exit 1
  fi
}

function validateSSLKeyStores()
{
   sudo chown -R $username:$groupname $KEYSTORE_PATH

   #validate identity keystore
   runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; keytool -list -v -keystore $customIdentityKeyStoreFileName -storepass $customIdentityKeyStorePassPhrase -storetype $customIdentityKeyStoreType | grep 'Entry type:' | grep 'PrivateKeyEntry'"

   if [[ $? != 0 ]]; then
       echo "Error : Identity Keystore Validation Failed !!"
       exit 1
   fi

   #validate Trust keystore
   runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; keytool -list -v -keystore $customTrustKeyStoreFileName -storepass $customTrustKeyStorePassPhrase -storetype $customTrustKeyStoreType | grep 'Entry type:' | grep 'trustedCertEntry'"

   if [[ $? != 0 ]]; then
       echo "Error : Trust Keystore Validation Failed !!"
       exit 1
   fi

   echo "ValidateSSLKeyStores Successfull !!"
}

function storeCustomSSLCerts()
{
    if [ "${isCustomSSLEnabled}" == "true" ];
    then

        mkdir -p $KEYSTORE_PATH

        echo "Custom SSL is enabled. Storing CertInfo as files..."
        export customIdentityKeyStoreFileName="$KEYSTORE_PATH/identity.keystore"
        export customTrustKeyStoreFileName="$KEYSTORE_PATH/trust.keystore"

        customIdentityKeyStoreData=$(echo "$customIdentityKeyStoreData" | base64 --decode)
        customIdentityKeyStorePassPhrase=$(echo "$customIdentityKeyStorePassPhrase" | base64 --decode)
        customIdentityKeyStoreType=$(echo "$customIdentityKeyStoreType" | base64 --decode)

        customTrustKeyStoreData=$(echo "$customTrustKeyStoreData" | base64 --decode)
        customTrustKeyStorePassPhrase=$(echo "$customTrustKeyStorePassPhrase" | base64 --decode)
        customTrustKeyStoreType=$(echo "$customTrustKeyStoreType" | base64 --decode)

        serverPrivateKeyAlias=$(echo "$serverPrivateKeyAlias" | base64 --decode)
        serverPrivateKeyPassPhrase=$(echo "$serverPrivateKeyPassPhrase" | base64 --decode)

        #decode cert data once again as it would got base64 encoded while  storing in azure keyvault
        echo "$customIdentityKeyStoreData" | base64 --decode > $customIdentityKeyStoreFileName
        echo "$customTrustKeyStoreData" | base64 --decode > $customTrustKeyStoreFileName

        validateSSLKeyStores

    else
        echo "Custom SSL is not enabled"
    fi
}

# Copy SerializedSystemIni.dat file from admin server vm to share point
function copySerializedSystemIniFileToShare()
{
  runuser -l oracle -c "cp ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat ${mountpointPath}/."
  ls -lt ${mountpointPath}/SerializedSystemIni.dat
  if [[ $? != 0 ]]; 
  then
      echo "Failed to copy ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat"
      exit 1
  fi
}

# Get SerializedSystemIni.dat file from share point to managed server vm
function getSerializedSystemIniFileFromShare()
{
  runuser -l oracle -c "mv ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat.backup"
  runuser -l oracle -c "cp ${mountpointPath}/SerializedSystemIni.dat ${DOMAIN_PATH}/${wlsDomainName}/security/."
  ls -lt ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat
  if [[ $? != 0 ]]; 
  then
      echo "Failed to get ${mountpointPath}/SerializedSystemIni.dat"
      exit 1
  fi
  runuser -l oracle -c "chmod 640 ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat"
}


# Create custom stopWebLogic script and add it to wls_admin service
# This script is created as stopWebLogic.sh will not work if non ssl admin listening port 7001 is disabled
# Refer https://github.com/wls-eng/arm-oraclelinux-wls/issues/164 
function createStopWebLogicScript()
{

cat <<EOF >${stopWebLogicScript}
#!/bin/sh
# This is custom script for stopping weblogic server using ADMIN_URL supplied
export ADMIN_URL="t3://${wlsAdminURL}"
${DOMAIN_PATH}/${wlsDomainName}/bin/stopWebLogic.sh
EOF

sudo chown -R $username:$groupname ${stopWebLogicScript}
sudo chmod -R 750 ${stopWebLogicScript}

}

#main script starts here

CURR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export BASE_DIR="$(readlink -f ${CURR_DIR})"

# store arguments in a special array 
args=("$@") 
# get number of elements 
ELEMENTS=${#args[@]} 
 
# echo each element in array  
# for loop 
for (( i=0;i<$ELEMENTS;i++)); do 
    echo "ARG[${args[${i}]}]"
done

if [ $# -le 8 ]
then
    usage
    exit 1
fi

export wlsDomainName=${1}
export wlsUserName=${2}
export wlsPassword=${3}
export wlsServerName=${4}
export wlsAdminHost=${5}
export oracleHome=${6}
export storageAccountName=${7}
export storageAccountKey=${8}
export mountpointPath=${9}

export isHTTPAdminListenPortEnabled="${10}"
isHTTPAdminListenPortEnabled="${isHTTPAdminListenPortEnabled,,}"

export isCustomSSLEnabled="${11}"
isCustomSSLEnabled="${isCustomSSLEnabled,,}"

#case insensitive check
if [ "${isCustomSSLEnabled}" == "true" ];
then
    echo "custom ssl enabled. Reading keystore information"
    export customIdentityKeyStoreData="${12}"
    export customIdentityKeyStorePassPhrase="${13}"
    export customIdentityKeyStoreType="${14}"
    export customTrustKeyStoreData="${15}"
    export customTrustKeyStorePassPhrase="${16}"
    export customTrustKeyStoreType="${17}"
    export serverPrivateKeyAlias="${18}"
    export serverPrivateKeyPassPhrase="${19}"
else
    isCustomSSLEnabled="false"
fi

validateInput

export coherenceListenPort=7574
export coherenceLocalport=42000
export coherenceLocalportAdjust=42200
export wlsAdminPort=7001
export wlsSSLAdminPort=7002
export wlsAdminT3ChannelPort=7005
export wlsManagedPort=8001

export DOMAIN_PATH="/u01/domains"
export startWebLogicScript="${DOMAIN_PATH}/${wlsDomainName}/startWebLogic.sh"
export stopWebLogicScript="${DOMAIN_PATH}/${wlsDomainName}/bin/customStopWebLogic.sh"

export wlsAdminURL="$wlsAdminHost:$wlsAdminT3ChannelPort"
export SERVER_START_URL="http://$wlsAdminURL"

export KEYSTORE_PATH="${DOMAIN_PATH}/${wlsDomainName}/keystores"

if [ "${isCustomSSLEnabled}" == "true" ];
then
   SERVER_START_URL="https://$wlsAdminHost:$wlsSSLAdminPort"
fi

export CHECK_URL="http://$wlsAdminURL/weblogic/ready"
export adminWlstURL="t3://$wlsAdminURL"

export wlsClusterName="cluster1"
export nmHost=`hostname`
export nmPort=5556
export WEBLOGIC_DEPLOY_TOOL=https://github.com/oracle/weblogic-deploy-tooling/releases/download/weblogic-deploy-tooling-1.8.1/weblogic-deploy.zip

export SCRIPT_PWD=`pwd`
export username="oracle"
export groupname="oracle"

cleanup

installUtilities
mountFileShare

if [ $wlsServerName == "admin" ];
then
  updateNetworkRules "admin"
  create_adminSetup
  createStopWebLogicScript
  create_nodemanager_service
  admin_boot_setup
  create_adminserver_service
  enabledAndStartNodeManagerService
  enableAndStartAdminServerService
  wait_for_admin
else
  updateNetworkRules "managed"
  create_managedSetup
  create_nodemanager_service
  enabledAndStartNodeManagerService
  wait_for_admin
  start_managed
fi

cleanup

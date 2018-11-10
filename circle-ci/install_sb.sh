#!/bin/bash
release=$(cat /tmp/release_to_build)
username=$(awk '/ssh_ansible_user:/{ if ($2 !~ /#.*/) {print $2}}' /tmp/config)
dns_name=$(awk '/dns_name:/{ if ($2 !~ /#.*/) {print $2}}' /tmp/config)
keycloak_pass=$(awk '/keycloak_admin_password:/{ if ($2 !~ /#.*/) {print $2}}' /tmp/config)
sso_pass=$(awk '/sso_password:/{ if ($2 !~ /#.*/) {print $2}}' /tmp/config)
cd /home/$username
mkdir .ssh 2> /dev/null
cp /tmp/sunbird.pem .ssh
git clone https://github.com/project-sunbird/sunbird-devops.git
cd sunbird-devops

IFS="/" read -r var1 var2 <<< $release

if [[ $var1 == "tags" ]]; then
   git checkout $release -b $var2
   echo -e "Installing sunbird $var2"
else
   git checkout -b $var1 origin/$var1
   echo -e "Installation sunbird $var1"
fi

cp /tmp/config ./deploy
cd deploy
echo -e "Starting installation..."
./sunbird_install.sh

if [[ $? -ne 0 ]]; then
   echo -e "Installation failed - Retrying..."
   ./sunbird_install.sh
fi

if [[ $? -eq 0 ]]; then
   echo -e "Sunbird installation complete - Starting core installation..."
   access_token=$(curl -s -X POST http://$dns_name/auth/realms/master/protocol/openid-connect/token -H "cache-control: no-cache" -H "content-type: application/x-www-form-urlencoded" -d "client_id=admin-cli&username=admin&password=$keycloak_pass&grant_type=password" | jq -r ".access_token")
   public_key=$(curl -s -X GET http://$dns_name/auth/admin/realms/sunbird/keys -H "Authorization: Bearer $access_token" -H "Cache-Control: no-cache" -H "Content-Type: application/json" | jq -r ".keys[0].publicKey")
   sed -i "s|sunbird_sso_publickey:|sunbird_sso_publickey: $public_key|g" config
   ./sunbird_install.sh -s core

   if [[ $? -eq 0 ]]; then
       jwt_token=$(cat /home/$username/jwt_token_player.txt | tr -d " ")
       access_token_user=$(curl -s -X POST http://$dns_name/auth/realms/sunbird/protocol/openid-connect/token -H "cache-control: no-cache" -H "content-type: application/x-www-form-urlencoded" -d "client_id=admin-cli&username=user-manager&password=$sso_pass&grant_type=password" | jq -r ".access_token")
       status=$(curl -s -X POST  http://$dns_name/api/org/v1/create -H "Cache-Control: no-cache" -H "Content-Type: application/json" -H "accept: application/json" -H "authorization: Bearer $jwt_token" -H "x-authenticated-user-token: $access_token_user" -d '{"request":{"orgName": "circle-ci", "description": "circle-ci", "isRootOrg": true, "channel": "circle-ci"}}' | jq -r ".result.response")
       if [[ $status == "SUCCESS" ]]; then
	  echo -e "Root org created successfully - Running core and posttest..."
	  ./sunbird_install.sh -s core
	  ./sunbird_install.sh -s posttest
	  echo -e "Sunbird installation complete"
       else
          echo -e "Sunbird installation failed - Unable to create root org"
	  exit 1
       fi
   fi
else
   echo -e "Sunbird installation failed - Error occured during installation."
   exit 1
fi

#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

if [[ "${BASH_TRACE:-0}" == "1" ]]; then
    set -o xtrace
fi

cd "$(dirname "$0")"

# STAGE 1 BASE

#### mkdir -p /opt/panoptes/
#### uv venv --python 3.14 --seed --relocatable --clear /opt/panoptes/.venv
#### /opt/panoptes/.venv/bin/pip install --upgrade --requirement /opt/panoptes/requirements.txt
/opt/panoptes/.venv/bin/python ./nftables.py  stage1-base
/opt/panoptes/.venv/bin/python ./templates.py stage1-base

sysctl --system
systemctl restart sshd.service
systemctl restart nftables.service
systemctl enable  dnf-automatic.timer
systemctl restart dnf-automatic.timer

if [ ! -d "/etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/" ]
then
    certbot --non-interactive register --agree-tos -m "certbot@$(hostname)" --no-eff-email
fi

if [ ! -d "/etc/letsencrypt/live/vpn/" ]
then
    certbot --non-interactive certonly --dns-route53 --domains "$(hostname)" --domains "$(hostname)" --cert-name vpn --pre-hook "systemctl stop strongswan.service openvpn-server@udp.service panoptes-portal.service" --post-hook 'systemctl restart strongswan.service openvpn-server@udp.service panoptes-portal.service'
fi

systemctl enable  certbot-renew.timer
systemctl restart certbot-renew.timer

# STAGE 2 FREERADIUS

/opt/panoptes/.venv/bin/python ./templates.py stage2-freeradius

rm -f /etc/raddb/mods-enabled/chap /etc/raddb/mods-enabled/exec /etc/raddb/mods-enabled/ntlm_auth

checkmodule -M -m -o /opt/freeradius/freeradius-rest.mod /opt/freeradius/freeradius-rest.te
semodule_package -o /opt/freeradius/freeradius-rest.pp -m /opt/freeradius/freeradius-rest.mod
semodule -i /opt/freeradius/freeradius-rest.pp

pushd /etc/raddb/certs/

rm --force 01.pem 02.pem 03.pem 04.pem 05.pem 06.pem 07.pem 08.pem ca.der ca.key ca.pem client.crt client.csr client.key index.* serial serial.* server.crt server.csr server.key server.p12 server.pem

if [ ! -e dh ]; then
  openssl dhparam -out dh 2048
  ln -sf /dev/urandom random
fi

if [ ! -e index.txt ]; then
  touch index.txt
fi

if [ ! -e serial ]; then
  echo '01' > serial
fi

if [ ! -e ca.key ]; then
  openssl req -new -x509 -keyout ca.key -out ca.pem -config ./ca.cnf
fi

if [ ! -e ca.der ]; then
  openssl x509 -inform PEM -outform DER -in ca.pem -out ca.der
fi

if [ ! -e server.key ]; then
  openssl req -new -keyout server.key -out server.csr -config ./server.cnf
  chmod g+r server.key
fi

if [ ! -e server.crt ]; then
  openssl ca -batch -keyfile ca.key -cert ca.pem -in server.csr -key `grep output_password ca.cnf | sed 's/.*=//;s/^ *//'` -out server.crt -extensions xpserver_ext -extfile xpextensions -config ./server.cnf
fi

if [ ! -e server.p12 ]; then
  openssl pkcs12 -export -in server.crt -inkey server.key -out server.p12  -passin pass:`grep output_password server.cnf | sed 's/.*=//;s/^ *//'` -passout pass:`grep output_password server.cnf | sed 's/.*=//;s/^ *//'`
  chmod g+r server.p12
fi

if [ ! -e server.pem ]; then
  openssl pkcs12 -in server.p12 -out server.pem -passin pass:`grep output_password server.cnf | sed 's/.*=//;s/^ *//'` -passout pass:`grep output_password server.cnf | sed 's/.*=//;s/^ *//'`
  openssl verify -CAfile ca.pem server.pem
  chmod g+r server.pem
fi

if [ ! -e client.key ]; then
  openssl req -new  -out client.csr -keyout client.key -config ./client.cnf
  chmod g+r client.key
fi

if [ ! -e client.crt ]; then
  openssl ca -batch -keyfile ca.key -cert ca.pem -in client.csr  -key `grep output_password ca.cnf | sed 's/.*=//;s/^ *//'` -out client.crt -extensions xpclient_ext -extfile xpextensions -config ./client.cnf
fi

chown root:radiusd dh ca.* client.* index.* serial.* server.*
chmod 640 dh ca.* client.* server.*

popd

systemctl enable  radiusd.service
systemctl restart radiusd.service

exit

systemctl enable  valkey.service
systemctl restart valkey.service


mkdir -p /etc/openvpn/server/client-config
chmod 755 /etc/openvpn/server/client-config

systemctl enable  dnsmasq.service
systemctl restart dnsmasq.service



systemctl enable  strongswan.service
systemctl restart strongswan.service

systemctl enable  strongswan.service
systemctl restart strongswan.service

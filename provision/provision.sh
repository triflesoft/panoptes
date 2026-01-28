#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

if [[ "${BASH_TRACE:-0}" == "1" ]]; then
    set -o xtrace
fi

cd "$(dirname "$0")"

if [ ! -f "templates/etc/pki/CA/certs/openvpn.key" ]
then
    certbot --non-interactive register --agree-tos -m "certbot@$(hostname)" --no-eff-email
fi

openssl genpkey -algorithm RSA -out templates/etc/pki/CA/private/vpn-ca.key      -pkeyopt rsa_keygen_bits:1024
openssl genpkey -algorithm RSA -out templates/etc/pki/tls/private/vpn-server.key -pkeyopt rsa_keygen_bits:1024

mkdir -p /opt/panoptes/
uv venv --python 3.14 --seed --relocatable --clear /opt/panoptes/.venv
/opt/panoptes/.venv/bin/pip install --upgrade --requirement /opt/panoptes/requirements.txt

/opt/panoptes/.venv/bin/python ./nftables.py
/opt/panoptes/.venv/bin/python ./templates.py stage1

sysctl --system
systemctl restart sshd.service
systemctl restart nftables.service
systemctl enable  dnf-automatic.timer
systemctl restart dnf-automatic.timer


exit




checkmodule -M -m -o templates/opt/freeradius/freeradius-rest.mod templates/opt/freeradius/freeradius-rest.te
semodule_package -o templates/opt/freeradius/freeradius-rest.pp -m templates/opt/freeradius/freeradius-rest.mod
semodule -i templates/opt/freeradius/freeradius-rest.pp

mkdir -p /etc/openvpn/server/client-config
chmod 755 /etc/openvpn/server/client-config

if [ ! -d "/etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/" ]
then
    certbot --non-interactive register --agree-tos -m "certbot@$(hostname)" --no-eff-email
fi

if [ ! -d "/etc/letsencrypt/live/vpn/" ]
then
    certbot --non-interactive certonly --dns-route53 --domains "$(hostname)" --domains "$(hostname)" --cert-name vpn --post-hook 'systemctl restart strongswan.service openvpn-server@udp.service'
fi

systemctl enable  certbot-renew.timer
systemctl restart certbot-renew.timer

systemctl enable  dnsmasq.service
systemctl restart dnsmasq.service

systemctl enable  radiusd.service
systemctl restart radiusd.service

systemctl enable  strongswan.service
systemctl restart strongswan.service

systemctl enable  strongswan.service
systemctl restart strongswan.service

#!/bin/bash

dnf update --assumeyes
dnf install --assumeyes amazon-efs-utils jq

EFS_ID="${efs_id}"
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "ad-blocker" --region ${region} --query SecretString --output text)
WARP_TOKEN=$(echo $SECRET_JSON | jq -r .warp_token)

TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
IP_PRIVATE=`curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4`

mkdir --parents /mnt/efs
mount --types efs --options tls $EFS_ID:/ /mnt/efs

mkdir --parents /mnt/efs/etc-pihole /mnt/efs/etc-dnsmasq.d
mkdir --parents /etc/pihole /etc/dnsmasq.d

mount --bind /mnt/efs/etc-pihole /etc/pihole
mount --bind /mnt/efs/etc-dnsmasq.d /etc/dnsmasq.d

export TZ='Europe/Madrid'
# export PIHOLE_SKIP_OS_CHECK=true

if [ ! -f /etc/pihole/pihole.toml ]; then
    cat <<EOT > /etc/pihole/pihole.toml
[dns.reply.host]
IPv4 = "$IP_PRIVATE"
EOT
fi

curl --silent --show-error --location https://install.pi-hole.net | bash /dev/stdin --unattended

curl --fail --silent --show-error --list-only https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo

dnf update --assumeyes
dnf install --assumeyes cloudflare-warp

sysctl -w net.ipv4.ip_forward=1

warp-cli --accept-tos connector new $WARP_TOKEN
warp-cli --accept-tos add-excluded-route 169.254.169.254/32
warp-cli --accept-tos connect

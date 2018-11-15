#!/bin/bash -x

set -o errexit

# Simple script to generate an image for vagrant on libvirt for Clear Releases

OUTDIR=$(mktemp -d -p `pwd` -t clr-vag.XXXXX)
CLR_VER=$(curl -s https://download.clearlinux.org/latest)
CLR_IMG="clear-${CLR_VER}-kvm.img"
MOUNT="${OUTDIR}/temp"
: ${BOX_NAME:="clearlinux"}
: ${OWNER:="gmmaha"}
: ${REPOSITORY:-${OWNER}/${BOX_NAME}}
: ${VAGRANT_CLOUD_TOKEN:-$(grep vagrantup ~/.netrc | awk '{print $6}')}

function build()
{
  echo "Getting clear version ${CLR_VER}..."
  curl --progress-bar https://download.clearlinux.org/image/${CLR_IMG}.xz -o ${OUTDIR}/${CLR_IMG}.xz
  unxz -v ${OUTDIR}/${CLR_IMG}.xz -c > ${OUTDIR}/${CLR_IMG}

  trap "{ sudo umount ${MOUNT} ; sudo qemu-nbd -d nbd10 ; }" EXIT ERR
  echo "Mount image to muddle with it..."
  mkdir ${MOUNT}
  sudo modprobe nbd max_part=63
  sudo qemu-nbd -f raw -c /dev/nbd10 ${OUTDIR}/${CLR_IMG}
  sleep 2
  sudo partprobe /dev/nbd10
  sudo mount /dev/nbd10p3 ${MOUNT}

  echo "Setup vagrant stuff..."
  sudo chroot ${MOUNT} bash -c 'useradd -m vagrant'
  sudo chroot ${MOUNT} bash -c 'mkdir -p /etc/sudoers.d/'
  sudo chroot ${MOUNT} bash -c 'echo "vagrant ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vagrant'
  sudo chroot ${MOUNT} bash -c 'mkdir -p /home/vagrant/.ssh'
  sudo chroot ${MOUNT} bash -c 'chmod 0700 /home/vagrant/.ssh'
  wget --no-check-certificate https://raw.githubusercontent.com/mitchellh/vagrant/master/keys/vagrant.pub -O ${OUTDIR}/authorized_keys
  sudo mv ${OUTDIR}/authorized_keys ${MOUNT}/home/vagrant/.ssh/authorized_keys
  sudo chroot ${MOUNT} bash -c 'chmod 0600 /home/vagrant/.ssh/authorized_keys'
  sudo chroot ${MOUNT} bash -c 'chown -R vagrant /home/vagrant/.ssh'
  sudo chroot ${MOUNT} bash -c 'mkdir -p /etc/ssh'
  sudo chroot ${MOUNT} bash -c 'cat << EOF > etc/ssh/sshd_config
  PubKeyAuthentication yes
  AuthorizedKeysFile %h/.ssh/authorized_keys
  PermitEmptyPasswords no
  PasswordAuthentication no
  EOF'
  sudo chroot ${MOUNT} bash -c 'systemctl enable sshd'

  echo "Start packaging..."
  sudo umount ${MOUNT}
  sudo qemu-nbd -d /dev/nbd10

  cat << EOF > ${OUTDIR}/metadata.json
{
  "provider": "libvirt",
  "format": "qcow2",
  "virtual_size": 40
}
EOF
  qemu-img convert -f raw -O qcow2 ${OUTDIR}/${CLR_IMG} ${OUTDIR}/box.qcow2
  mv ${OUTDIR}/box.qcow2 ${OUTDIR}/box.img
  GZIP=-5 tar -C ${OUTDIR} -cvzf ${OUTDIR}/clear-${CLR_VER}.box metadata.json box.img
}

function upload()
{
  if [ -z "$1" ]; then
    echo "Need version"
    exit 1
  fi
  if [ -z "$2" ]; then
    echo "Need box path"
    exit 1
  fi
  VER="$1"
  BOX_FILE="$2"
  echo "Create release for box..."
  curl --header "Content-Type: application/json" \
    --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
    https://app.vagrantup.com/api/v1/box/${REPOSITORY}/versions \
    --data '
  {
    "version": {
      "version": ${VER},
      "description": ""
    }
  }'

  echo "Create provider for release..."
  curl --header "Content-Type: application/json" \
    --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
    https://app.vagrantup.com/api/v1/box/${REPOSITORY}/version/${VER}/providers \
    --data '
  {
    "provider": {
      "name": "libvirt"
    }
  }'

  echo "Upload image..."
  response=$(curl \
    --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
    https://app.vagrantup.com/api/v1/box/${REPOSITORY}/version/${VER}/provider/libvirt/upload)
  upload_path=$(echo "${response}" | jq .upload_path)
  curl "${upload_path}" --request PUT \
    --upload_file ${BOX_FILE}

  echo "Releasing...."
  curl --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
    https://app.vagrantup.com/api/v1/box/${REPOSITORY}/version/${VER}/release \
    --request PUT
}

if [[ "$1" =~ ^(build|upload)$ ]]; then
  ${1} ${@}
else
  echo "Need either build or upload"
fi

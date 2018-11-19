#!/bin/bash

set -o errexit
set -o nounset

# Simple script to generate an image for vagrant on libvirt for Clear Releases

JOB=""
VER=""
BOX=""
CLR_VER=$(curl -s https://download.clearlinux.org/latest)
CLR_IMG="clear-${CLR_VER}-kvm.img"
: ${BOX_NAME:="clearlinux"}
: ${OWNER:="gmmaha"}
: ${REPOSITORY:=${OWNER}/${BOX_NAME}}
: ${VAGRANT_CLOUD_TOKEN:=$(grep vagrantup ~/.netrc | awk '{print $6}')}

function build()
{
  OUTDIR=$(mktemp -d -p `pwd` -t clr-vag.XXXXX)
  MOUNT="${OUTDIR}/temp"
  echo "Getting clear version ${CLR_VER}..."
  curl --progress-bar https://download.clearlinux.org/image/${CLR_IMG}.xz -o ${OUTDIR}/${CLR_IMG}.xz
  unxz -v ${OUTDIR}/${CLR_IMG}.xz -c > ${OUTDIR}/${CLR_IMG}

  # Resize the image
  qemu-img resize ${OUTDIR}/${CLR_IMG} 40G

  trap "{ sudo umount ${MOUNT} ; sudo qemu-nbd -d nbd10 ; }" EXIT ERR
  echo "Mount image to muddle with it..."
  mkdir ${MOUNT}
  sudo modprobe nbd max_part=63
  sudo qemu-nbd -f raw -c /dev/nbd10 ${OUTDIR}/${CLR_IMG}
  sleep 2

  #Grow partition size to end of device
  sudo partprobe /dev/nbd10
  sudo parted /dev/nbd10 resizepart fix 3 100%
  sudo e2fsck -f /dev/nbd10p3
  sudo resize2fs /dev/nbd10p3
  sudo mount /dev/nbd10p3 ${MOUNT}

  echo "Setup vagrant stuff..."
  sudo chroot ${MOUNT} bash -c 'useradd -m vagrant -p $(echo "vagrant" | openssl passwd -1 -stdin)'
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
EOF
'
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
  if [ -z "$VER" ]; then
    echo "Need version"
    exit 1
  fi
  if [ -z "$BOX" ]; then
    echo "Need to pass '-f <file.box>' with upload"
    exit 1
  fi
  echo "Create release for box..."
  curl --header "Content-Type: application/json" \
    --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
    https://app.vagrantup.com/api/v1/box/${REPOSITORY}/versions \
    --data '
  {
    "version": {
      "version": "'"${VER}"'",
      "description": ""
    }
  }' | jq .

  echo "Create provider for release..."
  curl --header "Content-Type: application/json" \
    --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
    https://app.vagrantup.com/api/v1/box/${REPOSITORY}/version/${VER}/providers \
    --data '
  {
    "provider": {
      "name": "libvirt"
    }
  }' | jq .

  echo "Upload image..."
  response=$(curl \
    --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
    https://app.vagrantup.com/api/v1/box/${REPOSITORY}/version/${VER}/provider/libvirt/upload)
  upload_path=$(echo "${response}" | jq .upload_path | tr -d \")
  curl ${upload_path} --request PUT \
    --upload-file ${BOX}

  echo "Releasing...."
  curl --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
    https://app.vagrantup.com/api/v1/box/${REPOSITORY}/version/${VER}/release \
    --request PUT | jq .
}

function test()
{
  # Remove previous boxes
  vagrant box remove clear-test
  sudo virsh vol-delete clear-test_vagrant_box_image_0.img --pool default
  vagrant box add --name clear-test ${BOX}
  vagrant up --provider=libvirt
}

function usage()
{
  echo ""
  echo " Usage: ${0} [-b|--build] [-u|--upload] [-t|--test]"
  echo ""
  echo "b|build: Build the box"
  echo "u|upload: Upload the box"
  echo "f|file: Path to file to upload to vagrant"
  echo "t|test: test the box"
  echo "h|help: Show help"
  echo ""
  exit 1
}

ARGS=$(getopt -o bhf:u:t: -l build,help,file:,upload:,test: -- "$@");

if [ $# -eq 0 ]; then usage; fi

eval set -- "$ARGS"

while true; do
  case "$1" in
    -b|--build) JOB="build"; shift ;;
    -u|--upload) JOB="upload"; VER="$2"; shift 2;;
    -f|--file) BOX="$2"; shift 2;;
    -t|--test) JOB="test"; BOX="$2"; shift 2;;
    -h|--help) usage;;
    --) shift; break;;
    *) usage;;
  esac
done

echo "Starting ${JOB}"

${JOB}

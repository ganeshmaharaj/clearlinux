# clearlinux
Stuff i have as extensions for clearlinux

## Multi-Node
My own vagrant file to spin up 3 nodes with 2 drives of 10G each, a private network and support for proxy

## Libvirt Images

Few things are needed for this to work
* OS loader image (https://download.clearlinux.org/image/OVMF.fd)
* Vagrant clearlinux plugin (https://github.com/AntonioMeireles/vagrant-guests-clearlinux)
  * `vagrant plugin install vagrant-guests-clearlinux`
* cpu_mode is set to `passthrough` in your Vagrantfile

## Temporary Hacks (2018-11-15)
The upstream plugin is pending on a merge of patch `https://github.com/AntonioMeireles/vagrant-guests-clearlinux/pull/1`. You might need to build it yourself and install that for NFS mounts to work.

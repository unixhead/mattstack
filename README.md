# mattstack

This script builds and installs Openstack Kilo release on Ubuntu 14.04 server (Trusty).
It was created as devstack does not persist during reboots, so I wanted a quick way to deploy Openstack. 

It's a scripted version of the Openstack guide linked below with some amendments to fix issues:
http://docs.openstack.org/kilo/install-guide/install/apt/content/index.html

To use it you should create a vanilla install of Ubuntu Server 14.04, set up internet access, download the script, chmod +x build-kilo.sh and run it as root.

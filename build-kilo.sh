#!/bin/bash
#
# Builds and installs openstack kilo on Ubuntu trusty (14).
# This is for development purposes, some of the security steps are skipped in the interest of the script working.
# The aim is to make something akin to devstack which survives reboots, instructions based on this:
# http://docs.openstack.org/kilo/install-guide/install/apt/content/index.html 
#
# Matt Bennett
# matt@unixhead.org
#


PASS="testpass"
IP="10.0.0.240"
#Network used to dish out IPs to hosts
NETWORK_CIDR="10.0.255.0/24"
INTERFACE="eth0"

ADMIN_TOKEN=`openssl rand -hex 10`

#I set all the passwords to the same thing, but they're defined separately here so you can modify if desired.
RABBIT_PASS=${PASS}
KEYSTONE_DB_PASS=${PASS}
DB_ROOT_PASS=${PASS}
DEMO_PASS=${PASS}
ADMIN_PASS=${PASS}
GLANCE_DB_PASS=${PASS}
GLANCE_PASS=${PASS}
NOVA_DB_PASS=${PASS}
NOVA_PASS=${PASS}
CINDER_DB_PASS=${PASS}
CINDER_PASS=${PASS}


OUTPUT=""



if [ "`/sbin/ifconfig | grep ${IP}`" == "" ]; then
	echo
	echo
	echo #################
	echo ##   WARNING   ##
	echo #################
	echo
	echo "This script will configure Openstack on IP address ${IP} but that address is not configured on this machine."
	echo "This will break the MySQL configuration, you need to configure ${IP} or amend this script."
	exit
fi


if [ "`/sbin/ifconfig | grep ${INTERFACE}`" == "" ]; then
	echo
	echo
	echo #################
	echo ##   WARNING   ##
	echo #################
	echo
	echo "This script will configure Openstack on interface ${INTERFACE} but that interface is not found on this machine"
	echo "Please amend script configuration to point to your network interface"
	exit
fi




#root check
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

#check ubuntu version
. /etc/lsb-release
if [ "${DISTRIB_CODENAME}" != "trusty" ]; then
	echo "This script is only supported on trusty (14.04)"
	exit 1
fi


#add the kilo repo
add-apt-repository cloud-archive:kilo
apt-get -y update 

#install mysql
export DEBIAN_FRONTEND=noninteractive
echo "mariadb-server-5.5 mysql-server/root_password password ${DB_ROOT_PASS}" | debconf-set-selections 
echo  "mariadb-server-5.5 mysql-server/root_password_again password ${DB_ROOT_PASS}" | debconf-set-selections

apt-get install -y mariadb-server python-mysqldb

#check that it did actually install - verify that DNS/etc is working on the host
if [ ! -f /etc/mysql/my.cnf ]; then
	echo "Failed to install MySQL, do you have Internet connectivity? Script exiting."
	exit 1
fi

sed -i -e "s/127.0.0.1/${IP}/" /etc/mysql/my.cnf 
service mysql restart

unset DEBIAN_FRONTEND
OUTPUT="${OUTPUT}SQL Database Installed\n"



#setup hostfile
echo "$IP controller" >> /etc/hosts
echo "$IP network" >> /etc/hosts
echo "$IP compute1" >> /etc/hosts


#Best practice is to run mysql_secure_installation but its interactive so not done here. This is just a dev box !

#rabbitMQ
apt-get install -y rabbitmq-server
rabbitmqctl add_user openstack ${RABBIT_PASS}
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

OUTPUT="${OUTPUT}RabbitMQ Installed\n"

#keystone ID engine
mysql -u root -p${PASS} -e 'CREATE DATABASE keystone;' 
mysql -u root -p${PASS} -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY \"${KEYSTONE_DB_PASS}\";"
mysql -u root -p${PASS} -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY \"${KEYSTONE_DB_PASS}\";"

echo "manual" > /etc/init/keystone.override
apt-get install -y keystone python-openstackclient apache2 libapache2-mod-wsgi #memcached python-memcache

mv /etc/keystone/keystone.conf /etc/keystone/keystone.conf.old

cat << EOF > /etc/keystone/keystone.conf
[DEFAULT]
admin_token = ${ADMIN_TOKEN}
#debug = true
verbose = true
log_dir = /var/log/keystone

[database]
connection = mysql://keystone:${KEYSTONE_DB_PASS}@controller/keystone

[revoke]
driver = keystone.contrib.revoke.backends.sql.Revoke

[token]
provider = keystone.token.providers.uuid.Provider
#note - not using memcached as per the OpenStack tutorial as it had issues for me
driver = keystone.token.persistence.backends.sql.Token

[extra_headers]
Distribution = Ubuntu

EOF

#keystone DB
/bin/sh -c "keystone-manage db_sync" keystone

#fix permissions on keystone config folders
chmod g+r /etc/keystone
chown -R :keystone /etc/keystone

#Apache setup for the identity service
echo "ServerName controller" >> /etc/apache2/apache2.conf

cat << EOF > /etc/apache2/sites-available/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /var/www/cgi-bin/keystone/main
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    LogLevel info
    ErrorLog /var/log/apache2/keystone-error.log
    CustomLog /var/log/apache2/keystone-access.log combined
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /var/www/cgi-bin/keystone/admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    LogLevel info
    ErrorLog /var/log/apache2/keystone-error.log
    CustomLog /var/log/apache2/keystone-access.log combined
</VirtualHost>

EOF


ln -s /etc/apache2/sites-available/wsgi-keystone.conf /etc/apache2/sites-enabled
mkdir -p /var/www/cgi-bin/keystone
curl http://git.openstack.org/cgit/openstack/keystone/plain/httpd/keystone.py?h=stable/kilo | tee /var/www/cgi-bin/keystone/main /var/www/cgi-bin/keystone/admin

chown -R keystone:keystone /var/www/cgi-bin/keystone
chmod 755 /var/www/cgi-bin/keystone/*

service apache2 restart
rm -f /var/lib/keystone/keystone.db

export OS_TOKEN=${ADMIN_TOKEN}
export OS_URL=http://controller:35357/v2.0

openstack service create --name keystone --description "OpenStack Identity" identity

openstack endpoint create \
  --publicurl http://controller:5000/v2.0 \
  --internalurl http://controller:5000/v2.0 \
  --adminurl http://controller:35357/v2.0 \
  --region RegionOne \
  identity

OUTPUT="${OUTPUT}Keystone Identity Service Installed\n"

#create projects/users/etc
openstack project create --description "Admin Project" admin
openstack user create --password ${ADMIN_PASS} admin
openstack role create admin
openstack role add --project admin --user admin admin
openstack project create --description "Service Project" service
openstack project create --description "Demo Project" demo
openstack user create --password ${DEMO_PASS} demo
openstack role create user
openstack role add --project demo --user demo user



mv /etc/keystone/keystone-paste.ini /etc/keystone/keystone-paste.ini.old

cat << EOF > /etc/keystone/keystone-paste.ini
# Keystone PasteDeploy configuration file.

[filter:debug]
paste.filter_factory = keystone.common.wsgi:Debug.factory

[filter:request_id]
paste.filter_factory = oslo_middleware:RequestId.factory

[filter:build_auth_context]
paste.filter_factory = keystone.middleware:AuthContextMiddleware.factory

[filter:token_auth]
paste.filter_factory = keystone.middleware:TokenAuthMiddleware.factory

[filter:admin_token_auth]
paste.filter_factory = keystone.middleware:AdminTokenAuthMiddleware.factory

[filter:json_body]
paste.filter_factory = keystone.middleware:JsonBodyMiddleware.factory

[filter:user_crud_extension]
paste.filter_factory = keystone.contrib.user_crud:CrudExtension.factory

[filter:crud_extension]
paste.filter_factory = keystone.contrib.admin_crud:CrudExtension.factory

[filter:ec2_extension]
paste.filter_factory = keystone.contrib.ec2:Ec2Extension.factory

[filter:ec2_extension_v3]
paste.filter_factory = keystone.contrib.ec2:Ec2ExtensionV3.factory

[filter:federation_extension]
paste.filter_factory = keystone.contrib.federation.routers:FederationExtension.factory

[filter:oauth1_extension]
paste.filter_factory = keystone.contrib.oauth1.routers:OAuth1Extension.factory

[filter:s3_extension]
paste.filter_factory = keystone.contrib.s3:S3Extension.factory

[filter:endpoint_filter_extension]
paste.filter_factory = keystone.contrib.endpoint_filter.routers:EndpointFilterExtension.factory

[filter:endpoint_policy_extension]
paste.filter_factory = keystone.contrib.endpoint_policy.routers:EndpointPolicyExtension.factory

[filter:simple_cert_extension]
paste.filter_factory = keystone.contrib.simple_cert:SimpleCertExtension.factory

[filter:revoke_extension]
paste.filter_factory = keystone.contrib.revoke.routers:RevokeExtension.factory

[filter:url_normalize]
paste.filter_factory = keystone.middleware:NormalizingFilter.factory

[filter:sizelimit]
paste.filter_factory = oslo_middleware.sizelimit:RequestBodySizeLimiter.factory

[app:public_service]
paste.app_factory = keystone.service:public_app_factory

[app:service_v3]
paste.app_factory = keystone.service:v3_app_factory

[app:admin_service]
paste.app_factory = keystone.service:admin_app_factory

[pipeline:public_api]
# The last item in this pipeline must be public_service or an equivalent
# application. It cannot be a filter.
pipeline = sizelimit url_normalize request_id build_auth_context token_auth json_body ec2_extension user_crud_extension public_service

[pipeline:admin_api]
# The last item in this pipeline must be admin_service or an equivalent
# application. It cannot be a filter.
pipeline = sizelimit url_normalize request_id build_auth_context token_auth json_body ec2_extension s3_extension crud_extension admin_service

[pipeline:api_v3]
# The last item in this pipeline must be service_v3 or an equivalent
# application. It cannot be a filter.
pipeline = sizelimit url_normalize request_id build_auth_context token_auth json_body ec2_extension_v3 s3_extension simple_cert_extension revoke_extension federation_extension oauth1_extension endpoint_filter_extension endpoint_policy_extension service_v3

[app:public_version_service]
paste.app_factory = keystone.service:public_version_app_factory

[app:admin_version_service]
paste.app_factory = keystone.service:admin_version_app_factory

[pipeline:public_version_api]
pipeline = sizelimit url_normalize public_version_service

[pipeline:admin_version_api]
pipeline = sizelimit url_normalize admin_version_service

[composite:main]
use = egg:Paste#urlmap
/v2.0 = public_api
/v3 = api_v3
/ = public_version_api

[composite:admin]
use = egg:Paste#urlmap
/v2.0 = admin_api
/v3 = api_v3
/ = admin_version_api
EOF


unset OS_TOKEN OS_URL

cat << EOF > admin-openrc.sh
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASS}
export OS_AUTH_URL=http://controller:35357/v3
EOF

#now run it
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASS}
export OS_AUTH_URL=http://controller:35357/v3

cat << EOF > demo-openrc.sh
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=demo
export OS_TENANT_NAME=demo
export OS_USERNAME=demo
export OS_PASSWORD=${DEMO_PASS}
export OS_AUTH_URL=http://controller:5000/v3
EOF


#add glance image service
mysql -u root -p${PASS} -e 'CREATE DATABASE glance;' 
mysql -u root -p${PASS} -e "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY \"${GLANCE_DB_PASS}\";"
mysql -u root -p${PASS} -e "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY \"${GLANCE_DB_PASS}\";"


openstack user create --password ${GLANCE_PASS} glance
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image service" image
openstack endpoint create \
  --publicurl http://controller:9292 \
  --internalurl http://controller:9292 \
  --adminurl http://controller:9292 \
  --region RegionOne \
  image


apt-get install -y glance python-glanceclient
mv /etc/glance/glance-api.conf /etc/glance/glance-api.conf.old

cat << EOF > /etc/glance/glance-api.conf
[DEFAULT]
verbose = true
bind_host = 0.0.0.0
bind_port = 9292
log_file = /var/log/glance/api.log
backlog = 4096
registry_host = 0.0.0.0
registry_port = 9191
registry_client_protocol = http
notification_driver = noop
rabbit_host = localhost
rabbit_port = 5672
rabbit_use_ssl = false
rabbit_userid = guest
rabbit_password = guest
rabbit_virtual_host = /
rabbit_notification_exchange = glance
rabbit_notification_topic = notifications
rabbit_durable_queues = False
qpid_notification_exchange = glance
qpid_notification_topic = notifications
qpid_hostname = localhost
qpid_port = 5672
qpid_username =
qpid_password =
qpid_sasl_mechanisms =
qpid_reconnect_timeout = 0
qpid_reconnect_limit = 0
qpid_reconnect_interval_min = 0
qpid_reconnect_interval_max = 0
qpid_reconnect_interval = 0
qpid_heartbeat = 5
qpid_protocol = tcp
qpid_tcp_nodelay = True
delayed_delete = False
scrub_time = 43200
scrubber_datadir = /var/lib/glance/scrubber
image_cache_dir = /var/lib/glance/image-cache/
[oslo_policy]
[database]
sqlite_db = /var/lib/glance/glance.sqlite
backend = sqlalchemy
connection = mysql://glance:${GLANCE_DB_PASS}@controller/glance
[oslo_concurrency]

[keystone_authtoken]
auth_uri = http://controller:5000
auth_url = http://controller:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = glance
password = ${GLANCE_PASS}

[paste_deploy]
flavor=keystone
[store_type_location_strategy]
[profiler]
[task]
[taskflow_executor]
[glance_store]
default_store = file
filesystem_store_datadir = /var/lib/glance/images/
swift_store_auth_version = 2
swift_store_auth_address = 127.0.0.1:5000/v2.0/
swift_store_user = jdoe:jdoe
swift_store_key = a86850deb2742ec3cb41518e26aa2d89
swift_store_container = glance
swift_store_create_container_on_put = False
swift_store_large_object_size = 5120
swift_store_large_object_chunk_size = 200
s3_store_host = s3.amazonaws.com
s3_store_access_key = <20-char AWS access key>
s3_store_secret_key = <40-char AWS secret key>
s3_store_bucket = <lowercased 20-char aws access key>glance
s3_store_create_bucket_on_put = False
sheepdog_store_address = localhost
sheepdog_store_port = 7000
sheepdog_store_chunk_size = 64
EOF


mv /etc/glance/glance-registry.conf /etc/glance/glance-registry.conf.old

cat << EOF > /etc/glance/glance-registry.conf
[DEFAULT]
verbose = true
bind_host = 0.0.0.0
bind_port = 9191
log_file = /var/log/glance/registry.log
backlog = 4096
api_limit_max = 1000
limit_param_default = 25
notification_driver = noop
rabbit_host = localhost
rabbit_port = 5672
rabbit_use_ssl = false
rabbit_userid = guest
rabbit_password = guest
rabbit_virtual_host = /
rabbit_notification_exchange = glance
rabbit_notification_topic = notifications
rabbit_durable_queues = False
qpid_notification_exchange = glance
qpid_notification_topic = notifications
qpid_hostname = localhost
qpid_port = 5672
qpid_username =
qpid_password =
qpid_sasl_mechanisms =
qpid_reconnect_timeout = 0
qpid_reconnect_limit = 0
qpid_reconnect_interval_min = 0
qpid_reconnect_interval_max = 0
qpid_reconnect_interval = 0
qpid_heartbeat = 5
qpid_protocol = tcp
qpid_tcp_nodelay = True

[oslo_policy]

[database]
sqlite_db = /var/lib/glance/glance.sqlite
backend = sqlalchemy
connection = mysql://glance:${GLANCE_DB_PASS}@controller/glance

[keystone_authtoken]
auth_uri = http://controller:5000
auth_url = http://controller:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = glance
password = ${GLANCE_PASS}

[paste_deploy]
flavor=keystone

[profiler]


EOF


/bin/sh -c "glance-manage db_sync" glance

service glance-registry restart
service glance-api restart
rm -f /var/lib/glance/glance.sqlite

OUTPUT="${OUTPUT}Glance Image Service Installed\n"

echo "export OS_IMAGE_API_VERSION=2" | tee -a admin-openrc.sh demo-openrc.sh
export OS_IMAGE_API_VERSION=2

mkdir /tmp/images
wget -P /tmp/images http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img
glance image-create --name "cirros-0.3.4-x86_64" --file /tmp/images/cirros-0.3.4-x86_64-disk.img \
  --disk-format qcow2 --container-format bare --visibility public --progress
rm -r /tmp/images

OUTPUT="${OUTPUT}Added cirros Linux image to Glance\n"

#nova
mysql -u root -p${PASS} -e 'CREATE DATABASE nova;' 
mysql -u root -p${PASS} -e "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY \"${NOVA_DB_PASS}\";"
mysql -u root -p${PASS} -e "GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY \"${NOVA_DB_PASS}\";"

openstack user create --password ${NOVA_PASS} nova
openstack role add --project service --user nova admin
openstack service create --name nova --description "OpenStack Compute" compute
openstack endpoint create \
  --publicurl http://controller:8774/v2/%\(tenant_id\)s \
  --internalurl http://controller:8774/v2/%\(tenant_id\)s \
  --adminurl http://controller:8774/v2/%\(tenant_id\)s \
  --region RegionOne \
  compute


apt-get install -y nova-api nova-cert nova-conductor nova-consoleauth \
  nova-novncproxy nova-scheduler python-novaclient nova-compute

OUTPUT="${OUTPUT}Nova Compute Installed\n"

mv /etc/nova/nova.conf /etc/nova/nova.conf.old

# note - uses legacy nova networking

cat << EOF > /etc/nova/nova.conf
[DEFAULT]
verbose=True
logdir=/var/log/nova
state_path=/var/lib/nova
lock_path=/var/lock/nova

api_paste_config=/etc/nova/api-paste.ini


network_manager = nova.network.manager.FlatDHCPManager
force_dhcp_release=True
dhcpbridge_flagfile=/etc/nova/nova.conf

dhcpbridge=/usr/bin/nova-dhcpbridge
libvirt_use_virtio_for_bridges=True

my_ip=${IP}
public_interface=${INTERFACE}
flat_interface=${INTERFACE}
flat_network_bridge = br100


vnc_enabled=true
vncserver_listen = 0.0.0.0
vncserver_proxyclient_address = ${IP}
novncproxy_base_url = http://${IP}:6080/vnc_auto.html

auth_strategy = keystone

network_api_class = nova.network.api.API
security_group_api = nova
firewall_driver = nova.virt.libvirt.firewall.IptablesFirewallDriver
network_size = 254
allow_same_net_traffic = False

[database]
connection = mysql://nova:${NOVA_DB_PASS}@controller/nova

[oslo_messaging_rabbit]
rabbit_host = controller
rabbit_userid = openstack
rabbit_password = ${RABBIT_PASS}

[keystone_authtoken]
auth_uri = http://controller:5000
auth_url = http://controller:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = nova
password = ${NOVA_PASS}     

[glance]
host = controller

[oslo_concurrency]
lock_path = /var/lib/nova/tmp
EOF

/bin/sh -c "nova-manage db sync" nova

# see if hardware accel enabled, if not then force qemu
HWACC=`egrep -c '(vmx|svm)' /proc/cpuinfo`
echo $HWACC
if [ "${HWACC}" == "0" ]; then
	apt-get install -y nova-compute-qemu
	OUTPUT="${OUTPUT}Installing Qemu for non-accelerated compute (nested virtualisation?)\n"
	echo "Virtualised Hardware Acceleration not enabled in the CPU, enabling the qemu hypervisor"
	echo "[libvirt]" >> /etc/nova/nova.conf
	echo "inject_partition = -2" >> /etc/nova/nova.conf
	echo "use_usb_table = false" >> /etc/nova/nova.conf
	echo "cpu_mode = none" >> /etc/nova/nova.conf
	echo "virt_type = qemu" >> /etc/nova/nova.conf
	service nova-compute restart
fi


apt-get install -y sysfsutils nova-network 

service nova-api restart
service nova-cert restart
service nova-consoleauth restart
service nova-scheduler restart
service nova-conductor restart
service nova-novncproxy restart
service nova-network restart
service nova-api-metadata restart

rm -f /var/lib/nova/nova.sqlite

nova network-create demo-net --bridge br100 --multi-host T \
  --fixed-range-v4 ${NETWORK_CIDR}

OUTPUT="${OUTPUT}Legacy Nova Networking Enabled with IP range ${NETWORK_CIDR}\n"

#install the web dashboard

apt-get install -y openstack-dashboard

cp /etc/openstack-dashboard/local_settings.py /etc/openstack-dashboard/local_settings.py.old
sed -i -e "s/OPENSTACK_HOST = \"127.0.0.1\"/OPENSTACK_HOST = \"controller\"/" /etc/openstack-dashboard/local_settings.py
sed -i -e "s/_member_/user/" /etc/openstack-dashboard/local_settings.py

service apache2 restart

OUTPUT="${OUTPUT}\nHorizon Web Dashboard Installed, browse to it on http://${IP}/horizon\nLog in with username:admin and password:${ADMIN_PASS}\n\n"


#install cinder block storage
mysql -u root -p${PASS} -e 'CREATE DATABASE cinder;' 
mysql -u root -p${PASS} -e "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY \"${CINDER_DB_PASS}\";"
mysql -u root -p${PASS} -e "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY \"${CINDER_DB_PASS}\";"

openstack user create --password ${CINDER_PASS} cinder
openstack role add --project service --user cinder admin
openstack service create --name cinder --description "OpenStack Block Storage" volume
openstack service create --name cinderv2 --description "OpenStack Block Storage" volumev2
openstack endpoint create \
  --publicurl http://controller:8776/v2/%\(tenant_id\)s \
  --internalurl http://controller:8776/v2/%\(tenant_id\)s \
  --adminurl http://controller:8776/v2/%\(tenant_id\)s \
  --region RegionOne \
  volume

openstack endpoint create \
  --publicurl http://controller:8776/v2/%\(tenant_id\)s \
  --internalurl http://controller:8776/v2/%\(tenant_id\)s \
  --adminurl http://controller:8776/v2/%\(tenant_id\)s \
  --region RegionOne \
  volumev2

apt-get install -y cinder-api cinder-scheduler python-cinderclient cinder-volume python-mysqldb


mv /etc/cinder/cinder.conf /etc/cinder/cinder.conf.old

cat << EOF > /etc/cinder/cinder.conf
[DEFAULT]
rootwrap_config = /etc/cinder/rootwrap.conf
api_paste_confg = /etc/cinder/api-paste.ini
iscsi_helper = tgtadm
volume_name_template = volume-%s
volume_group = cinder-volumes
verbose = True
auth_strategy = keystone
state_path = /var/lib/cinder
lock_path = /var/lock/cinder
volumes_dir = /var/lib/cinder/volumes
rpc_backend = rabbit
my_ip = ${IP}
enabled_backends = lvm

[database]
connection = mysql://cinder:${CINDER_DB_PASS}@controller/cinder

[oslo_messaging_rabbit]
rabbit_host = controller
rabbit_userid = openstack
rabbit_password = ${RABBIT_PASS}

[keystone_authtoken]
auth_uri = http://controller:5000
auth_url = http://controller:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = cinder
password = ${CINDER_PASS}

[oslo_concurrency]
lock_path = /var/lock/cinder

[lvm]
volume_driver = cinder.volume.drivers.lvm.LVMVolumeDriver
volume_group = cinder-volumes
iscsi_protocol = iscsi
iscsi_helper = tgtadm

EOF

/bin/sh -c "cinder-manage db sync" cinder

OUTPUT="${OUTPUT}Cinder Block Storage Installed\n"

if [ "`vgs | grep cinder-volumes`" == "" ]; then
 OUTPUT="${OUTPUT}No LVM volume group called cinder-volumes was found, you need to create this for the block storage service to function\n"
fi

service cinder-scheduler restart
service cinder-api restart
service tgt restart
service cinder-volume restart
rm -f /var/lib/cinder/cinder.sqlite






echo 
echo
echo -e ${OUTPUT}
echo
echo "Please reboot your system to complete the installation and get all services running"
echo "Instances won't load until you do !"
echo
echo "To use the CLI tools run:"
echo "source admin-openrc.sh"

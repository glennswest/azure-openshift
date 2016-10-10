#!/bin/bash

export RESOURCEGROUP=$1
export AUSERNAME=$2
export PASSWORD=$3
export HOSTNAME=$4
export NODECOUNT=$5
export ROUTEREXTIP=$6
export RHNUSERNAME=$7
export RHNPASSWORD=$8
export RHNPOOLID=$9
export SSHPRIVATEDATA=${10}
export SSHPUBLICDATA=${11}
export SSHPUBLICDATA2=${12}
export SSHPUBLICDATA3=${13}

ps -ef | grep bastion.sh > cmdline.out

mkdir -p /home/$AUSERNAME/.ssh
echo $SSHPUBLICDATA $SSHPUBLICDATA2 $SSHPUBLICDATA3 >  /home/$AUSERNAME/.ssh/id_rsa.pub
echo $SSHPRIVATEDATA | base64 --d > /home/$AUSERNAME/.ssh/id_rsa
chown $AUSERNAME /home/$AUSERNAME/.ssh/id_rsa.pub
chmod 600 /home/$AUSERNAME/.ssh/id_rsa.pub
chown $AUSERNAME /home/$AUSERNAME/.ssh/id_rsa
chmod 600 /home/$AUSERNAME/.ssh/id_rsa

mkdir -p /root/.ssh
echo $SSHPRIVATEDATA | base64 --d > /root/.ssh/id_rsa
echo $SSHPUBLICDATA $SSHPUBLICDATA2 $SSHPUBLICDATA3   >  /root/.ssh/id_rsa.pub
chown root /root/.ssh/id_rsa.pub
chmod 600 /root/.ssh/id_rsa.pub
chown root /root/.ssh/id_rsa
chmod 600 /root/.ssh/id_rsa

sleep 30
cat <<EOF > /root/setup_ssmtp.sh
# \$1 = Gmail Account (Leave off @gmail.com ie user)
# \$2 = Gmail Password
# \$3 = Notification email address
# Setup ssmtp mta agent for use with gmail
yum -y install wget
wget -c https://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-8.noarch.rpm
rpm -ivh epel-release-7-8.noarch.rpm
yum -y install ssmtp
alternatives --set mta  /usr/sbin/sendmail.ssmtp
systemctl stop postfix
systemctl disable postfix
cat <<EOFZ > /etc/ssmtp/ssmtp.conf
root=postmaster
mailhub=mail
TLS_CA_File=/etc/pki/tls/certs/ca-bundle.crt
mailhub=smtp.gmail.com:587   # SMTP server for Gmail
Hostname=localhost
UseTLS=YES
UseSTARTTLS=Yes
FromLineOverride=YES #TO CHANGE FROM EMAIL
Root=\${3} # Redirect root email
AuthUser=\${1}@gmail.com
AuthPass=\${2}
AuthMethod=LOGIN
RewriteDomain=gmail.com
EOFZ
cat <<EOFZ > /etc/ssmtp/revaliases
root:\${1}@gmail.com:smtp.gmail.com:587
EOFZ
EOF
chmod +x /root/setup_ssmtp.sh
# Ignore Error If It Dont work
/root/setup_ssmtp.sh ${AUSERNAME} ${PASSWORD} ${RHNUSERNAME} || true

echo "${RESOURCEGROUP} Bastion Host is starting software update" | mail -s "${RESOURCEGROUP} Bastion Software Install" ${RHNUSERNAME} &
# Continue Setting Up Bastion
subscription-manager unregister 
yum -y remove RHEL7
rm -f /etc/yum.repos.d/rh-cloud.repo
subscription-manager register --username $RHNUSERNAME --password $RHNPASSWORD
subscription-manager attach --pool=$RHNPOOLID
subscription-manager repos --disable="*"
subscription-manager repos     --enable="rhel-7-server-rpms"     --enable="rhel-7-server-extras-rpms"
subscription-manager repos     --enable="rhel-7-server-ose-3.3-rpms"
yum -y install atomic-openshift-utils
yum -y install git net-tools bind-utils iptables-services bridge-utils bash-completion httpd-tools
yum -y install docker
touch /root/.updateok
sed -i -e "s#^OPTIONS='--selinux-enabled'#OPTIONS='--selinux-enabled --insecure-registry 172.30.0.0/16'#" /etc/sysconfig/docker
                                                                                         
cat <<EOF > /etc/sysconfig/docker-storage-setup
DEVS=/dev/sdc
VG=docker-vg
EOF

docker-storage-setup                                                                                                                                    
systemctl enable docker
systemctl start docker


cat <<EOF > /etc/ansible/hosts
[OSEv3:children]
masters
etcd
nodes
misc

[OSEv3:vars]
azure_resource_group=${RESOURCEGROUP}
rhn_pool_id=${RHNPOOLID}
openshift_install_examples=true
deployment_type=openshift-enterprise
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

# default selectors for router and registry services
openshift_router_selector='region=infra'
openshift_registry_selector='region=infra'

ansible_become=yes
ansible_ssh_user=${AUSERNAME}
remote_user=${AUSERNAME}

openshift_master_default_subdomain=${ROUTEREXTIP}.xip.io 
openshift_use_dnsmasq=False
openshift_public_hostname=${RESOURCEGROUP}.trafficmanager.net

openshift_master_cluster_method=native
openshift_master_cluster_hostname=${RESOURCEGROUP}.trafficmanager.net
openshift_master_cluster_public_hostname=${RESOURCEGROUP}.trafficmanager.net

# Enable cockpit
osm_use_cockpit=true

# Set cockpit plugins
osm_cockpit_plugins=['cockpit-kubernetes']

# default storage plugin dependencies to install, by default the ceph and
# glusterfs plugin dependencies will be installed, if available.
osn_storage_plugin_deps=['iscsi']

[masters]
master1 openshift_node_labels="{'role': 'master'}"
master2 openshift_node_labels="{'role': 'master'}"
master3 openshift_node_labels="{'role': 'master'}"

[etcd]
master1
master2
master3

[nodes]
master1 openshift_node_labels="{'region':'master','zone':'default'}" 
master2 openshift_node_labels="{'region':'master','zone':'default'}" 
master3 openshift_node_labels="{'region':'master','zone':'default'}" 
node[01:${NODECOUNT}] openshift_node_labels="{'region': 'primary', 'zone': 'default'}"
infranode openshift_node_labels="{'region': 'infra', 'zone': 'default'}"


[misc]
store1
bastion
EOF


cat <<EOF > /home/${AUSERNAME}/subscribe.yml
---
- hosts: all
  vars:
    description: "Subscribe OSE"
  tasks:
  - name: check connection
    ping:
  - Wait for the initial part of the startup scripts to be done
    wait_for: path=/root/.updateok
  - name: Update all hosts via Azure Repos
    yum: name=* state=latest
    ignore_errors: yes
  - name: Get rid of rhui repos
    file: path=/etc/yum.repos.d/rh-cloud.repo state=absent
  - name: Get rid of rhui Load balancers
    file: path=/etc/yum.repos.d/rhui-load-balancers state=absent
  - name: remove the RHUI package
    yum: name=RHEL7 state=absent
  - name: Get rid of old subs
    shell: subscription-manager unregister
    ignore_errors: yes
  - name: register hosts
    shell: subscription-manager register --username ${RHNUSERNAME} --password ${RHNPASSWORD} 
    register: task_result
    until: task_result.rc == 0
    retries: 10
    delay: 30
    ignore_errors: yes
  - name: attach sub
    shell: subscription-manager attach --pool=$RHNPOOLID
    register: task_result
    until: task_result.rc == 0
    retries: 10
    delay: 30
    ignore_errors: yes
  - name: disable all repos
    shell: subscription-manager repos --disable="*" 
  - name: enable rhel7 repo
    shell: subscription-manager repos --enable="rhel-7-server-rpms"
  - name: enable extras repos
    shell: subscription-manager repos --enable="rhel-7-server-extras-rpms"
  - name: enable ose repos
    shell: subscription-manager repos --enable="rhel-7-server-ose-3.3-rpms"
  - name: install the latest version of PyYAML
    yum: name=PyYAML state=latest
  - name: Install the ose client
    yum: name=atomic-openshift-clients state=latest
  - name: Install iscsi initiator utils
    yum: name=iscsi-initiator-utils state=latest
  - name: add new initiator name
    lineinfile: dest=/etc/iscsi/initiatorname.iscsi create=yes regexp="InitiatorName=*" line="InitiatorName=iqn.2016-02.local.azure.nodes" state=present
  - name: restart iscsid service
    shell: systemctl restart iscsi
    ignore_errors: yes
  - name: Enable Iscsi
    shell: systemctl enable iscsi
    ignore_errors: yes
  - name: Start iScsi Initiator  Service
    shell: systemctl start iscsi
    ignore_errors: yes
  - name: Discover Devices on Iscsi  All Hosts
    shell: iscsiadm --mode discovery --type sendtargets --portal store1
    register: task_result
    until: task_result.rc == 0
    retries: 10
    delay: 30
    ignore_errors: yes
  - name: Login All Hosts
    shell: iscsiadm --mode node --portal store1 --login
    register: task_result
    until: task_result.rc == 0
    retries: 10
    delay: 30
    ignore_errors: yes
  - name: Update all hosts
    yum: name=* state=latest

EOF


cat <<EOF > /home/${AUSERNAME}/postinstall.yml
---
- hosts: masters
  vars:
    description: "auth users"
  tasks:
  - name: Create Master Directory
    file: path=/etc/origin/master state=directory
  - name: add initial user to OpenShift Enterprise
    shell: htpasswd -c -b /etc/origin/master/htpasswd ${AUSERNAME} ${PASSWORD}

EOF

cat <<EOF > /home/${AUSERNAME}/openshift-install.sh
export ANSIBLE_HOST_KEY_CHECKING=False
ansible-playbook /home/${AUSERNAME}/subscribe.yml
ansible all --module-name=ping > ansible-preinstall-ping.out
echo "${RESOURCEGROUP} Bastion Host is starting ansible BYO" | mail -s "${RESOURCEGROUP} Bastion BYO Install" ${RHNUSERNAME} &
ansible-playbook  /usr/share/ansible/openshift-ansible/playbooks/byo/config.yml < /dev/null &> byo.out
# ssh gwest@master1 oadm registry --selector=region=infra
# ssh gwest@master1 oadm router --selector=region=infra
wget http://master1:8443/api > healtcheck.out
ansible-playbook /home/${AUSERNAME}/postinstall.yml
cd /root
mkdir .kube
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${AUSERNAME}@master1:~/.kube/config /tmp/kube-config
cp /tmp/kube-config /root/.kube/config
mkdir /home/${AUSERNAME}/.kube
cp /tmp/kube-config /home/${AUSERNAME}/.kube/config
chown --recursive ${AUSERNAME} /home/${AUSERNAME}/.kube
rm -f /tmp/kube-config
echo "${RESOURCEGROUP} Installation Is Complete" | mail -s "${RESOURCEGROUP} Install Complete" ${RHNUSERNAME} &
EOF

cat <<EOF > /home/${AUSERNAME}/.ansible.cfg
[defaults]
remote_tmp     = ~/.ansible/tmp
local_tmp      = ~/.ansible/tmp
host_key_checking = False
forks=30
gather_timeout=60
timeout=240
[ssh_connection]
control_path = ~/.ansible/cp/ssh%%h-%%p-%%r
ssh_args = -o ControlMaster=auto -o ControlPersist=600s -o ControlPath=~/.ansible/cp-%h-%p-%r
EOF
chown ${AUSERNAME} /home/${AUSERNAME}/.ansible.cfg
  
cat <<EOF > /root/.ansible.cfg
[defaults]
remote_tmp     = ~/.ansible/tmp
local_tmp      = ~/.ansible/tmp
host_key_checking = False
forks=30
gather_timeout=60
timeout=240
[ssh_connection]
control_path = ~/.ansible/cp/ssh%%h-%%p-%%r
ssh_args = -o ControlMaster=auto -o ControlPersist=600s -o ControlPath=~/.ansible/cp-%h-%p-%r
EOF


cd /home/${AUSERNAME}
chown ${AUSERNAME} /home/${AUSERNAME}/openshift-install.sh
chmod 755 /home/${AUSERNAME}/openshift-install.sh
echo "${RESOURCEGROUP} Bastion Host is starting Openshift Install" | mail -s "${RESOURCEGROUP} Bastion Openshift Install" ${RHNUSERNAME} &
/home/${AUSERNAME}/openshift-install.sh &> /home/${AUSERNAME}/openshift-install.out &
exit 0


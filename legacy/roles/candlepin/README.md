ansible-role-candlepin
=========

An Ansible role that installs and deploys Candlepin for development or testing purposes.

This role is intended for use with newer Candlepin branches, but the resultant environment may still be used
with older builds with some minor tweaks or configuration changes within the environment after provisioning.

Requirements
------------

Candlepin has many requirements for its developers. You will need a Fedora or CentOS box, or RHEL with EPEL
enabled to use this role. It is recommmended that that box has a non-root user to run Candlepin on (see
variables below).

Role Variables
--------------

There are a number of variables which enable various features and aspects of a developer environment. The
primary flow control variables are the six boolean variables listed below:

- `cp_deploy`: whether or not Candlepin will be deployed after provisionining the system; defaults to true

For some of these tasks, some operations may be modified or configured by changing further variables. A full
list of variables which are intended to be modified on a per-environment basis can be found in the
`defaults/main.yml` file.

User Configuration
------------------

By default, Candlepin will be cloned and deployed from the `devel` directory in the `candlepin` user's home
directory, but this can be modified by changing the three Candlepin home or user variables listed below:

- `candlepin_user`: the user to install, build, and run as; defaults to "candlepin"
- `candlepin_user_home`: the home directory of the selected user; defaults to "/home/{{candlepin_user}}"
- `candlepin_home`: the home directory for the Candlepin checkout or mapping; defaults to
  "{{ candlepin_user_home }}/devel/candlepin"

In many cases, this can be left as-is. However, in the case of a Vagrant deployment, it is likely these will
need to be changed accordingly. For example, in a typical Vagrant setup where the Candlepin repo is mapped in
from the host, these variables might be configured as follows:

```yaml
  ansible_user: vagrant
  candlepin_user: vagrant
  candlepin_home: /vagrant
```

Deploying Candlpin
------------------

By default, this role will deploy Candlepin if the repo exists in the configured location. The deployment
can be configured by passing args accepted by Candlepin's deployment tool. See the documentation associated
with that tool for details on its parameters.

- `cp_deploy`: whether or not to deploy Candlepin as part of the provisioning step; defaults to true
- `cp_deploy_args`: the arguments to pass to the Candlepin deploy tool; defaults to "-gta"

By default, Candlepin will be deployed in a way that drops and re-creates its database from scratch, imports
synthetic test data, and then regenerates the candlepin.conf with default settings for PostgreSQL support.

Vagrant Integration
-------------------

This role can be used with Vagrant to quickly spin up a VM with a fully prepared development environment. In
such cases, it is heavily advised to set the `candlepin_user` variable accordingly, at minimum.

An example playbook for Vagrant use is as follows:

```yaml
---
- hosts: all

  roles:
    - role: candlepin

  vars:
    ansible_user: vagrant
    candlepin_user: vagrant
    candlepin_home: /vagrant

    cp_deploy: false
```

The above playbook would provision the VM with PostgreSQL support, configure the user environment,
and configure Tomcat for remote debugging and profiling. It would not, obviously, deploy it.

Unit Testing & Molecule
-----------------------

The unit tests will run on github actions; to run the unit tests locally you will need ansible, molecule and its drivers.

To install molecule run the following.

```sh
pip3 install molecule molecule[podman] molecule-containers
```

You might also want ansible-lint with `pip3 install ansible-lint` or `yum install python3-ansible-lint`.
To run unit tests simply run `molecule test`.  By default this will test on `fedora35`, or you can
`export MOLECULE_DISTRO='centos8'` (or `centos7`) to change the test target.

License
-------

GPLv2

Author Information
------------------

See [official documentation](http://www.candlepinproject.org).

# frozen_string_literal: true

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-22.04"

  cluster_nodes = {
    "consul" => {
      ip: "192.168.56.10",
      memory: 1024,
      cpus: 1,
      role_script: "vagrant/provision/consul.sh"
    },
    "nomad-server" => {
      ip: "192.168.56.11",
      memory: 2048,
      cpus: 2,
      role_script: "vagrant/provision/nomad-server.sh"
    },
    "nomad-client" => {
      ip: "192.168.56.12",
      memory: 3072,
      cpus: 2,
      role_script: "vagrant/provision/nomad-client.sh"
    },
    "vault" => {
      ip: "192.168.56.13",
      memory: 1024,
      cpus: 1,
      role_script: "vagrant/provision/vault.sh"
    }
  }

  cluster_nodes.each do |name, node|
    config.vm.define name do |machine|
      machine.vm.hostname = name
      machine.vm.network "private_network", ip: node[:ip]

      machine.vm.provider "virtualbox" do |vb|
        vb.name = "openstudio-#{name}"
        vb.memory = node[:memory]
        vb.cpus = node[:cpus]
      end

      machine.vm.provider "parallels" do |prl|
        prl.name = "openstudio-#{name}"
        prl.memory = node[:memory]
        prl.cpus = node[:cpus]
      end

      # Uncomment to use VMware Fusion / Workstation.
      # Requires the `vagrant-vmware-desktop` plugin and VMware Utility.
      # machine.vm.provider "vmware_desktop" do |vmw|
      #   vmw.vmx["displayName"] = "openstudio-#{name}"
      #   vmw.vmx["memsize"] = node[:memory].to_s
      #   vmw.vmx["numvcpus"] = node[:cpus].to_s
      # end

      machine.vm.provision "shell", path: "vagrant/provision/common.sh"
      machine.vm.provision "shell", path: node[:role_script]
    end
  end
end

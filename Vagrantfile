Vagrant.configure("2") do |config|
  config.vm.box = "ubuntubtrfs/ubuntu-22.04"
  config.vm.box_version = "1.0.2"
  config.vm.hostname = "ubuntu-btrfs-management"

  # config.vm.synced_folder '.', '/vagrant', disabled: true

  # Hyper-V specific configuration
  config.vm.provider "hyperv" do |h|
    h.vmname = "ubuntu-btrfs-management"
    h.memory     = 1024   # startup memory
    h.maxmemory  = 4096   # max memory
    h.cpus   = 2
    # h.enable_virtualization_extensions = true
  end

  # Use PowerShell as required by Hyper-V
  config.vm.guest = :ubuntu
  config.vm.communicator = "ssh"

  # config.vm.provision "shell", inline: <<-SHELL
  #   bash /vagrant/install.sh
  # SHELL
end

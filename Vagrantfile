require 'yaml'

# Path to the credentials file
credentials_file = File.expand_path('smbcredentials.yaml')

# Function to prompt for input
def prompt(msg, hide_input=false)
  print msg
  if hide_input
    system("stty -echo") # hide input
    input = $stdin.gets.chomp
    system("stty echo")
    puts
  else
    input = $stdin.gets.chomp
  end
  input
end

# Load or create credentials
credentials = {}

if File.exist?(credentials_file)
  credentials = YAML.load_file(credentials_file) || {}
end

# Ensure required fields
%w[username password].each do |field|
  if credentials[field].nil? || credentials[field].empty?
    credentials[field] = prompt("Enter your Windows #{field}: ", field == "password")
  end
end

# Write back credentials if file didn't exist or was missing fields
unless File.exist?(credentials_file) && %w[username password].all? { |f| credentials[f] && !credentials[f].empty? }
  File.open(credentials_file, 'w') { |f| f.write(credentials.to_yaml) }
  puts "Credentials saved to #{credentials_file}"
end

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntubtrfs/ubuntu-22.04"
  config.vm.box_version = "1.0.2"
  config.vm.hostname = "ubuntu-btrfs-management"

  config.vm.synced_folder '.', '/vagrant',
    smb_username: credentials['username'],
    smb_password: credentials['password'],
    # type: "rsync",
    disabled: false

  # Hyper-V specific configuration
  config.vm.provider "hyperv" do |h|
    h.vmname = "ubuntu-btrfs-management"
    h.memory     = 1024   # startup memory
    h.maxmemory  = 4096   # max memory
    h.cpus   = 2
  
    h.enable_virtualization_extensions = true
    h.linked_clone = true
  end

  # Use PowerShell as required by Hyper-V
  config.vm.guest = :ubuntu
  config.vm.communicator = "ssh"

  if Vagrant.has_plugin?("vagrant-timezone")
    config.timezone.value = :host
  end

  config.vm.provision "shell", inline: <<-SHELL
    bash /vagrant/install.sh
  SHELL
end

lxd 'default' do
  network_address '[::]'
  auto_upgrade true
  users 'travis' if ENV['TRAVIS'] == 'true'
end

lxd_network 'lxdbr0'
lxd_profile 'default'

lxd_device 'eth0' do
  location :profile
  location_name 'default'
  type :nic
  parent 'lxdbr0'
  nictype :bridged
end

if ENV['TRAVIS'] == 'true'
  directory "#{ENV['HOME']}/.config" do
    owner 'travis'
  end

  directory "#{ENV['HOME']}/.config/lxc" do
    owner 'travis'
  end

  file "#{ENV['HOME']}/.config/lxc/config.yml" do
    owner 'travis'
  end
end

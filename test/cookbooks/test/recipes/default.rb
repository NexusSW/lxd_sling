lxd 'default' do
  network_address '[::]'
  auto_upgrade true
  branch :lts
  branch :feature if (node['lsb']['codename'] == 'xenial') || (ENV['TRAVIS'] == 'true')
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

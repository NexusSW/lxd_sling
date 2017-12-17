lxd 'default' do
  branch :feature
  network_address '[::]'
  network_port '8443'
  trust_password 'blahsee'
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

lxd 'default' do
  branch :feature
  network_address '[::]'
  network_port '8443'
  trust_password 'blahsee'
end

lxd_network 'lxdbr0' do
  ipv4_address :auto
  action [:rename, :create]
end

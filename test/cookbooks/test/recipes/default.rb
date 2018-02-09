lxd 'default' do
  network_address '[::]'
  auto_upgrade true
  branch :lts
  branch :feature if (node['lsb']['codename'] == 'xenial') || (ENV['TRAVIS'] == 'true')
  users 'travis' if ENV['TRAVIS'] == 'true'
end

if ENV['TRAVIS'] == 'true'
  directory "#{ENV['HOME']}/.config" do
    owner 'travis'
    group 'travis'
  end

  directory "#{ENV['HOME']}/.config/lxc" # we only want the notify upon ownership change
  directory "#{ENV['HOME']}/.config/lxc" do
    owner 'travis'
    group 'travis'
    notifies :run, 'execute[chown]', :immediately
  end

  execute 'chown' do
    command "chown travis:travis #{ENV['HOME']}/.config/lxc/*"
    action :nothing
  end
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

require 'yaml'

property :server_path, String, identity: true # default: '/var/lib/lxd',
property :branch, Symbol, default: :feature, equal_to: [:feature, :lts]
property :auto_install, [true, false], default: false, desired_state: false
property :auto_upgrade, [true, false], default: false, desired_state: false
property :keep_bridge, [true, false], default: false, desired_state: false
property :version, String

# Config properties
property :network_address, String
property :network_port, String, default: '8443'
property :trust_password, String, sensitive: true
property :users, [Array, String]
property :certificate_file, String
property :certificate_key, String # the filename isn't sensitive, but the contents are (handled on the File resource)
# property :raw_config, Hash

resource_name :lxd
default_action :init

# Strategy:  we'll always do a snap install when the feature branch is specified.  It's the only 'official' way afaik.
#   and while we could get it from xenial-backports, I do believe that will version cap at 2.21
# releases prior to Bionic will get 2.0.x when lts is specified.  Bionic will get 3.0.x.
#   (basically whatever version is available in the official package repo)
#   (i don't 'think' bionic-backports will be getting the 3.x feature packages - TBD)
# when I get around to non-ubuntu images where lxd probably isn't in the dist repos...
#   I might need to contrive some additional logic for verion resolution - TBD
#     afaik snap will still be the primary means, but snap channels 'may' help with that

load_current_value do
  lxd = Chef::Recipe::LXD.new node, server_path
  server_path lxd.lxd_dir
  return unless lxd.installed?
  begin
    info = lxd.info
  rescue Mixlib::ShellOut::ShellCommandFailed
    return # The service must not be running if 'lxc info' won't work
  end

  address = info['config']['core.https_address']
  network_port address.slice!(/:[0-9]*$/).sub(':', '') if address
  network_address address if address
  branch lxd.installed?(:lts) ? :lts : :feature
  # raw_config info['config'] # TODO: normalize this to exclude any global configs that we seperately configure
  version info['environment']['server_version'].tr '"', ''
end

# the server_path property is included, but we're not supporting multiple installations of lxd
# afaic just nest if you want to do some form of seperation (Issues and PR's welcome if you have a use case)
# but the server_path property is there because it combines to form into some systemd service names
#   just in case I need them later - (this seems to be not true for snap installs)
#   and I use it to locate the server certs
#   and this allows the user to override that value in cases where 'they' did the multi-install and are just pointing us to it
#     on that note, we'll go ahead and supply the `LXD_DIR=#{new_resource.server_path}` environment variable in our system calls
#       that ends our support for this function

action :upgrade do
  # by default, newer lxd does not install a bridge - so for parity with :install, remove the inherited bridge, which is whacked, anyways, if it was a vanilla 2.0.x default bridge (xenial)
  # the thinking is that the consumer will be setting one up in their recipe anyways, because they'll need to for parity with other dists
  if !new_resource.keep_bridge && lxd.installed?(:lts) && (new_resource.branch == :feature)
    lxd_network 'lxdbr0' do
      server_path new_resource.server_path
      action :delete
      ignore_failure true # TODO: needs tested - i 'think' lxd will error if the bridge is in use, and that is 'ok', and preferred.  If it doesn't, then I could code that
      only_if "grep '^LXD_IPV6_PROXY=\"true\"' /etc/default/lxd-bridge"
    end
    lxd_device 'eth0' do
      server_path new_resource.server_path
      location :profile
      location_name 'default'
      action :nothing
      subscribes :delete, 'lxd_network[lxdbr0]', :before
    end
  end

  do_install :upgrade
end

action :install do
  do_install
end

action :init do
  unless lxd.installed?(new_resource.branch)
    raise "Cannot install the #{new_resource.branch} branch of LXD on this version of this platform (#{node['lsb']['codename']})" unless can_install?(new_resource.branch)
    raise "The #{new_resource.branch} branch of LXD is not available for configuration.  Is it installed?" unless should_install?(new_resource.branch)
  end

  we_installed = false
  was_installed = lxd.installed?
  if new_resource.auto_install || new_resource.auto_upgrade
    new_resource.auto_upgrade ? action_upgrade : action_install
    we_installed = true unless was_installed
  end

  # just in case we just migrated from ppa to snap
  lxd.lxd_dir = lxd.default_lxd_dir if lxd.default_lxd_dir?

  service_name = snap? ? 'snap.lxd.daemon' : 'lxd'
  # run `lxd init --auto` - though not strictly required, it's just good form...
  service service_name do
    action [:enable, :start]
    not_if { snap? && (node['init_package'] == 'init') } # kludge for snap lxd on upstart
  end
  restart_service = false
  if we_installed
    cmd = 'lxd init --auto'
    if new_resource.network_address
      cmd += " --network-address #{new_resource.network_address}"
      cmd += " --network-port #{new_resource.network_port}"
    end
    converge_by 'initializing LXD' do
      lxd.exec! cmd
    end
  elsif new_resource.network_address
    converge_if_changed :network_address, :network_port do
      lxd.exec! "lxc config set core.https_address #{new_resource.network_address}:#{new_resource.network_port}"
      restart_service = true
    end
  end

  if property_is_set?(:trust_password) && !lxd.test_password(new_resource.trust_password)
    converge_by 'setting trust password' do
      lxd.exec_sensitive! "lxc config set core.trust_password '#{new_resource.trust_password}'"
      lxd.save_password_hash lxd.password_hash(new_resource.trust_password)
    end
  end

  group 'lxd' do
    members new_resource.users
    action :modify
    append true
  end if property_is_set? :users

  file File.join(lxd.lxd_dir, 'server.crt') do
    content File.read(new_resource.certificate_file)
    owner 'root'
    group 'root'
    mode '0644'
    action :create
    notifies :run, 'ruby_block[delayed-restart-lxd]', :immediately
  end if property_is_set? :certificate_file

  file File.join(lxd.lxd_dir, 'server.key') do
    content File.read(new_resource.certificate_key)
    owner 'root'
    group 'root'
    mode '0600'
    sensitive true
    action :create
    notifies :run, 'ruby_block[delayed-restart-lxd]', :immediately
  end if property_is_set? :certificate_key

  ruby_block 'delayed-restart-lxd' do
    block do
      restart_service = true
    end
    action :nothing
  end

  if snap? && (node['init_package'] == 'init') # kludge for snap lxd on upstart
    execute 'snap restart lxd' do
      only_if { restart_service }
    end
  else
    service service_name do
      action :restart
      only_if { restart_service }
    end
  end

  execute 'waitready' do
    command 'lxd waitready --timeout 300'
    only_if { restart_service }
  end
end

action_class do
  include Chef::Recipe::LXD::ActionMixin

  def do_install(perform = :install)
    raise "Cannot install the #{new_resource.branch} branch of LXD on this version of this platform (#{node['lsb']['codename']})" unless can_install?(new_resource.branch)
    warn 'The LTS release of LXD was requested, but a newer version is already installed...  Continuing.' if (new_resource.branch == :lts) && lxd.installed?(:feature)

    apt_update 'update' if node['platform_family'] == 'debian'

    if should_snap?
      apt_package 'squashfuse' do
        only_if { (node['virtualization']['system'] == 'lxd') && (node['virtualization']['role'] == 'guest') }
      end
      package 'snapd' # watchout: there could be PATH issues here, after this, if snap was not previously installed...
      execute 'install-lxd' do
        command 'snap install lxd'
        not_if 'snap list lxd'
      end
      # wait for startup or migrate will fail
      execute 'waitready' do
        command '/snap/bin/lxd waitready --timeout 300'
        action :nothing
        subscribes :run, 'execute[install-lxd]', :immediately
      end
      execute 'migrate' do
        command 'lxd.migrate --yes'
        only_if 'test -f /usr/bin/lxc'
      end
      file '/etc/default/lxd-bridge' do
        action :delete
      end
    else
      apt_package 'lxd' do
        default_release 'trusty-backports' if (node['lsb']['codename'] == 'trusty') && (new_resource.branch == :lts)
        version new_resource.version if property_is_set? :version
        action perform
      end
    end
  end

  def can_install?(_branch)
    return false unless node['platform'] == 'ubuntu'
    case new_resource.branch
    when :lts then node['platform_version'].split('.')[0].to_i >= 14
    when :feature then can_snap?
    end
  end

  def can_snap?
    # isinstalled || should be able to install if systemd is running ||
    #   should be able to install systemd on trusty unless we're a container (enable snap on travis' full vm)
    node['packages']['snapd'] || (node['init_package'] == 'systemd') ||
      ((node['lsb']['codename'] == 'trusty') &&
        (!node['virtualization'].key?('role') || (node['virtualization']['role'] == 'host') ||
        (node['virtualization']['role'] == 'guest') && !%w(lxc lxd docker).index(node['virtualization']['system'])))
  end

  def snap?
    lxd.lxd_dir.start_with?('/var/snap/')
  end

  def should_snap?
    can_snap? && (new_resource.branch == :feature)
  end

  # watch out:  the only caller atm is action_init, which incorporates auto_install
  def should_install?(branch)
    (new_resource.auto_install || new_resource.auto_upgrade) && !lxd.installed?(branch) && can_install?(branch)
  end
end

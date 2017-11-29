require 'yaml'

require 'pp'

property :server_path, String, default: '/var/lib/lxd', identity: true
property :branch, Symbol, default: :lts, equal_to: [:feature, :lts]
property :auto_install, [true, false], default: true, desired_state: false
property :auto_upgrade, [true, false], default: true, desired_state: false
property :version, String

# Config properties
property :network_address, String
property :network_port, String, default: '8443'
property :trust_password, String, sensitive: true
property :users, [Array, String]
property :certificate_file, String
property :certificate_key, String
property :raw_config, Hash

resource_name :lxd
default_action :init

load_current_value do
  lxd = Chef::Recipe::LXD.new node, server_path
  return unless lxd.installed?
  info = lxd.info

  address = info['config']['core.https_address']
  network_port address.slice!(/:[0-9]*$/).sub(':', '') if address
  network_address address if address
  branch lxd.installed?(:lts) ? :lts : :feature
  raw_config info['config'] # TODO: normalize this to exclude any global configs that we seperately configure
  version info['environment']['server_version'] # if node['lxd'] && node['lxd'].key?('version_pin')
end

# the server_path property is included, but we're not supporting multiple installations of lxd
# afaic just nest if you want to do some form of seperation (Issues and PR's welcome if you have a use case)
# but the server_path property is there because it combines to form into some systemd service names
#   just in case I need them later
#   and this allows the user to override that value in cases where 'they' did the multi-install and are just pointing us to it
#     on that note, we'll go ahead and supply the `LXD_DIR=#{new_resource.server_path}` environment variable in our system calls
#       that ends our support for this function
#       bear in mind that none of my upstream work supports this (yet) (if i need to incorporate my upstream work)

action :upgrade do
  do_install
  edit_resource!(:package, 'lxd') do
    action :upgrade
  end
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
  if new_resource.auto_install # always install regardless of necessity in hopes of picking up security updates
    new_resource.auto_upgrade ? action_upgrade : action_install
    we_installed = true unless was_installed
  end

  # init properties
  # property :network_address, String
  # property :network_port, Integer, default: 8443

  # property :trust_password, [String], sensitive: true, desired_state: false
  # property :raw_config, Hash

  # other properties
  # property :users, [Array, String], desired_state: false
  # property :certificate_file, String, desired_state: false
  # property :certificate_key, String, desired_state: false

  # run `lxd init --auto` - though not strictly required, it's just good form...
  service 'lxd' do
    action [:enable, :start]
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
  else
    converge_if_changed :network_address, :network_port do
      lxd.exec! "lxc config set core.https_address #{new_resource.network_address}:#{new_resource.network_port}"
      restart_service = true
    end if new_resource.network_address
  end

  if property_is_set?(:trust_password) && !lxd.test_password(new_resource.trust_password)
    converge_by 'setting trust password' do
      lxd.exec_sensitive! "lxc config set core.trust_password '#{new_resource.trust_password}'"
      lxd.save_password_hash lxd.password_hash(new_resource.trust_password)
    end
  end

  service 'lxd' do
    action :restart
    only_if { restart_service }
  end
end

action_class do
  def lxd
    @lxd ||= Chef::Recipe::LXD.new node, new_resource.server_path
  end

  def do_install
    raise "Cannot install the #{new_resource.branch} branch of LXD on this version of this platform (#{node['lsb']['codename']})" unless can_install?(new_resource.branch)
    warn 'The LTS release of LXD was requested, but a newer version is already installed...  Continuing.' if (new_resource.branch == :lts) && lxd.installed?(:feature)

    include_recipe 'lxd::lxd_from_package'

    # :lts is a soft-pin on the stable version of lxd
    #   it 'should' be safe to not version pin on the :lts branch in order to receive security patches & fixes
    #     unless you're super strict and/or want to control the rollout

    # Trusty: no functioning package available by default
    #   backports contains :lts 2.0.x
    # Xenial: :lts package available by default 2.0.x
    #   backports contains latest canonical CI validated :feature 2.x

    # using repo gives the latest greatest :feature no matter os version - 2.x
    #   and this will shield us in case xenial-backports gets a version cap like trusty-backports - it'll continue to roll forward
    #   and upstream is pro so I'm not too worried about the extra testing
    #     if you're using the feature branch without a version pin, then assumedly you're in a dev/CI environment anyways

    # untested, but at this point I'm assuming for newer zesty+
    #   that you'll get the CI tested :feature when specifying :lts, or latest repo version for :feature
    #   I'll rework the soft pins when bionic is released, if needed (and this will be a major version bump if there are changes)
    #     when bionic releases, I assume there will be a new :lts pin, and I'll have to come up with a good name for the old :lts
    #     as noted below, it's also possible that I'll have to do nothing, and just let the dist dictate what version :lts refers to
    #
    # I'm not explicitly supporting downgrading - use a version pin (untested - it 'should' work?)
    #
    # 2.21 will be the final feature release before 3.0 alpha release in January
    #   still TBD which will be in bionic - but I'm hoping 3.0?  That'll make things nice & consistent
    #   the PPA is EOL after December, so the only install meduims will be backports & snap
    #     TBD if there will be a backports in bionic
    #
    # Once I'm done with this cookbook, I'm going to come back through here and rewrite to allow for snap installs(?)
    #   snap appears to be the only way we'll be able to install on other distros
    #   the challenge will be the change in folder structure, so try to stay away from specifics as much as possible in the mean time
    #   I might wind up going away from the lxd cookbook if i have to do too much more myself
    #     the use of their recipes are becoming fringe, so may as well keep it all in house

    edit_resource!(:package, 'lxd') do
      default_release 'trusty-backports'
    end if (node['lsb']['codename'] == 'trusty') && (new_resource.branch == :lts)

    # Assumption for bionic:
    #   just like xenial, stable repo will have whatver they call :lts
    #     and we can just use the lxd repo to get the feature branch instead of backports
    # so do I really need the lts16/18 aliases?
    # it appears that the distro will dictate what version you get with :lts
    #   except for the above case with trusty, which will go away with bionic's release

    # uncomment in this block if propwerty_is_set? doesn't distinguish between caller set & load_current_value
    if property_is_set? :version
      # node.normal['lxd']['version_pin'] = new_resource.version
      edit_resource!(:package, 'lxd') do
        version new_resource.version
        # version node['lxd']['version_pin']
      end
    end

    # This PPA will be gone after December...
    # Recommendations is to use backports, or snap packages
    #   backports will eventually be phased as well
    #   leaving long term methods being what's installed by the distro and/or what's in their core package system, or install by snap
    use_repo = (new_resource.branch == :feature) || property_is_set?(:version)
    edit_resource!(:apt_repository, 'lxd') do
      only_if { use_repo }
    end
  end

  def can_install?(_branch)
    node['platform'] == 'ubuntu'
    # return false unless node['platform'] == 'ubuntu'
    # case branch
    # when :lts then node['platform_version'].split('.')[0].to_i >= 14
    # when :feature then node['platform_version'].split('.')[0].to_i >= 16
    # end
  end

  # watch out:  the only caller atm is action_init, which incorporates auto_install
  def should_install?(branch)
    new_resource.auto_install && !lxd.installed?(branch) && can_install?(branch)
  end
end

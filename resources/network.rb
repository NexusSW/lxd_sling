require 'yaml'
require 'pp'

property :network_name, String, name_property: true
property :server_path, String, default: '/var/lib/lxd', identity: true
property :profiles, Array, coerce: ->(profile) { [profile].flatten }

property :bridge_driver, Symbol, equal_to: [:native, :openvswitch], default: :native, coerce: ->(val) { val.to_sym }
property :bridge_external_interfaces, String, coerce: ->(iface) { iface.is_a?(String) ? iface : iface.join(',') }
property :bridge_mode, Symbol, equal_to: [:standard, :fan], default: :standard, coerce: ->(val) { val.to_sym }
property :bridge_mtu, Integer, default: 1500, coerce: ->(val) { val.to_i }

property :raw_dnsmasq, String
property :dns_domain, String, default: 'lxd'
property :dns_mode, Symbol, equal_to: [:none, :managed, :dynamic], default: :managed, coerce: ->(val) { val.to_sym }

property :fan_overlay_subnet, String, default: '240.0.0.0/8'
property :fan_type, Symbol, equal_to: [:vxlan, :ipip], default: :vxlan, coerce: ->(val) { val.to_sym }
property :fan_underlay_subnet, String

property :ipv4_address, [String, Symbol], default: :auto, callbacks: {
  'Invalid IPv4 address' => ->(addr) { addr.is_a?(String) || [:auto, :none].include?(addr) },
}
property :ipv4_dhcp, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv4_dhcp_expiry, Integer, default: 3600, coerce: ->(val) { val.to_i }
property :ipv4_dhcp_ranges, [String, Symbol], default: :auto, coerce: ->(range) { (range.is_a?(String) || range == :auto) ? range : range.join(',') }, callbacks: {
  'Invalid IPv4 DHCP range' => ->(range) { range.is_a?(String) || (range == :auto) },
}
property :ipv4_firewall, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv4_nat, [true, false], coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv4_routes, String, coerce: ->(route) { route.is_a?(String) ? route : route.join(',') }
property :ipv4_routing, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }

property :ipv6_address, [String, Symbol], default: :auto, callbacks: {
  'Invalid IPv6 address' => ->(addr) { addr.is_a?(String) || [:auto, :none].include?(addr) },
}
property :ipv6_dhcp, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv6_dhcp_expiry, Integer, default: 3600, coerce: ->(val) { val.to_i }
property :ipv6_dhcp_ranges, String, coerce: ->(range) { range.is_a?(String) ? range : range.join(',') }
property :ipv6_dhcp_stateful, [true, false], default: false, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv6_firewall, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv6_nat, [true, false], coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv6_routes, String, coerce: ->(route) { route.is_a?(String) ? route : route.join(',') }
property :ipv6_routing, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }

resource_name :lxd_network

# the overarching goal with new vs old bridge:
#   - old_bridge is immediately deprecated so I'm not interested in anything 'special' that it might be capable of over the new bridge (e.g. IPV6_PROXY)
#   - old_bridge is installed by default on xenial, so it'll be around for a while, but will eventually go away as the newer versions become
#       'as' stable as the 2.0.x branch, and feature rich enough to entice upgrades
#   - our properties are written for the new_bridge
#       and the code to handle the old_bridge intends to mimic the behaviour of the new_bridge, given the same properties, in order to ease the upgrade path
#   - TODO: we'll pop some warnings if you're using a new setting that I can't map to the old_bridge (there are many)
#       and although I may be able to figure it all out with :raw_dnsmasq settings,
#       I'd prefer to leave that to the consumer (or make them upgrade) rather than write a bunch of deprecated throw-away code
#         (not to mention convoluting convergence upon :raw_dnsmasq)
load_current_value do
  lxd = Chef::Recipe::LXD.new node, server_path
  begin
    new_bridge = lxd.info['api_extensions'].include? 'network'
  rescue Mixlib::ShellOut::ShellCommandFailed
    # escape clause to allow reconfiguring a borked old-bridge (in which case the lxd service won't start & 'lxc info' won't work)
    new_bridge = !::File.exist?('/etc/default/lxd-bridge')
    raise if new_bridge
  end
  if new_bridge
    begin
      net = YAML.load lxd.exec! "lxc network show #{network_name}"
    rescue Mixlib::ShellOut::ShellCommandFailed
      # 'lxc info' succeeded (so the service is running) or else new_bridge could not have been true
      return # so the network does not exist
    end
    net['config'].each do |k, v|
      prop = k.tr('.', '_')
      send(prop, v) if respond_to? prop
    end
  else # old bridge code
    ipv4 = {}
    ipv6 = {}
    IO.readlines('/etc/default/lxd-bridge').each do |line|
      val = line[/="(.*)"/, 1]
      next if !val || val.empty?
      case line.split('=')[0].strip
      when 'LXD_BRIDGE' then network_name val # this seems to not take effect (name_property)
      when 'LXD_CONFILE' then raw_dnsmasq val
      when 'LXD_DOMAIN' then dns_domain val
      when 'LXD_IPV4_ADDR' then ipv4[:address] = val
      when 'LXD_IPV4_NETWORK' then ipv4[:mask] = line[%r{=".*/(.*)"}, 1]
      when 'LXD_IPV4_DHCP_RANGE' then ipv4_dhcp_ranges val.tr(',', '-') # only one range supported
      when 'LXD_IPV4_NAT' then ipv4_nat val
      when 'LXD_IPV6_ADDR' then ipv6[:address] = val
      when 'LXD_IPV6_MASK' then ipv6[:mask] = val
      when 'LXD_IPV6_NAT' then ipv6_nat val
      end
    end
    ipv4_address "#{ipv4[:address]}/#{ipv4[:mask]}" unless ipv4.empty?
    ipv6_address "#{ipv6[:address]}/#{ipv6[:mask]}" unless ipv6.empty?
  end
end

EXCLUDE_AUTO_PROPS = [:network_name, :server_path, :profiles].freeze
KEY_OVERRIDES = {
  fan_underlay_subnet: 'fan.underlay_subnet',
  fan_overlay_subnet: 'fan.overlay_subnet',
  bridge_external_interfaces: 'bridge.external_interfaces',
}.freeze

action :create do
  return action_modify if network_exists?
  raise "The current LXD bridge does not have the same name (#{new_resource.network_name}).  Use the :rename action if this is intended." unless new_bridge?
  cmd = 'lxc network create ' + new_resource.network_name
  # this is a new resource - don't worry about 'current_resource'.  This did not exist during load_current_value
  new_resource.class.state_properties.each do |prop|
    val = new_resource.send(prop.name)
    next if EXCLUDE_AUTO_PROPS.include? prop.name
    # my property defaults are intended to match LXD's defaults
    # - beware the conditional default on the nat settings
    # - and also of differing behaviours between releases after setup
    #   - trusty is unconfigured and has no lxdbr0
    #   - xenial has lxdbr0 and has 'none' for the addresses and 'dynamic' for dns.mode
    next unless property_is_set?(prop.name)
    next if (prop.name == :ipv4_dhcp_ranges) && (val.to_s == 'auto') # 'auto' is an invalid value, but I needed to introduce it for an edge case with the old_bridge
    cmd << " #{key_name(prop)}='#{val}'" if val
  end
  converge_by "create LXD network (#{new_resource.network_name})" do
    lxd.exec! cmd
  end
end

action :modify do
  unless network_exists?
    raise "The current LXD bridge does not have the same name (#{new_resource.network_name}).  Use the :rename action if this is intended." unless new_bridge?
    raise "LXD network (#{network_name}) does not exist."
  end
  if new_bridge?
    new_resource.class.state_properties.each do |prop|
      val = new_resource.send(prop.name)
      next if EXCLUDE_AUTO_PROPS.include? prop.name
      if val.to_s == 'auto'
        next if prop.name == :ipv4_dhcp_ranges # 'auto' is an invalid value, but I needed to introduce it for an edge case with the old_bridge

        # don't reapply 'auto' if a value has already been set (it'll change the value)
        #   e.g. ipv4_address: current_resource contains the automatically generated address, while new_resource contains 'auto' so it wants to converge
        next if current_resource.send(prop.name)
      end
      converge_if_changed prop.name do
        lxd.exec! "lxc network set #{new_resource.network_name} #{key_name(prop)} '#{val}'"
      end
    end
  else # old bridge
    ipv4 = resolve_ipv4(new_resource.ipv4_address)
    ipv6 = resolve_ipv6(new_resource.ipv6_address)
    service_name = node['lsb']['codename'] == 'trusty' ? 'lxd' : 'lxd-bridge'
    service service_name do
      action :nothing
      action [:enable, :start] if service_name == 'lxd-bridge'
      retries 2 # on trusty - :stop works, but errors, if the network is presently 'deleted'
    end
    template OLD_BRIDGE_FILE do
      source 'lxd-bridge.erb'
      variables resource: {
        network_name: new_resource.network_name,
        raw_dnsmasq: new_resource.raw_dnsmasq,
        dns_domain: new_resource.dns_domain,
        ipv4_address: ipv4,
        ipv4_netmask: ipv4_netmask(ipv4),
        ipv4_dhcp_ranges: old_ipv4_dhcp_range(ipv4, new_resource.ipv4_dhcp_ranges),
        ipv4_nat: resolve_ipv4_nat(new_resource.ipv4_nat),
        ipv6_address: ipv6,
        ipv6_nat: resolve_ipv6_nat(new_resource.ipv6_nat),
      }
      owner 'root'
      group 'root'
      mode '0644'
      action :create
      notifies :stop, "service[#{service_name}]", :before
      notifies :restart, "service[#{service_name}]", :immediately
    end
  end
end

# the old lxd ecosystem can only manage one bridge at a time.  We need some way to error if the user tries to set up 2+ bridges
# so in the 'old-way' we'll require the names to match before converging, and the :rename action is included to make the user cognizant
# so if you want to set up a bridge named other than 'lxdbr0', then include the :rename action first in your recipe
# in the 'new-way' where multiple bridges are allowed, this is a no-op since there is no single source of truth for old-name

# Deprecated - to be removed when I abandon the 2.0.x branch of LXD
action :rename do
  if new_bridge?
    warn 'The :rename action is deprecated and has no effect on this version of LXD'
    return
  end
  service_name = node['lsb']['codename'] == 'trusty' ? 'lxd' : 'lxd-bridge'
  service service_name do
    action :enable
  end

  execute 'rename' do
    command "sed -i '/^LXD_BRIDGE=/s/=\".*\"/=\"#{new_resource.network_name}\"/' #{OLD_BRIDGE_FILE}"
    notifies :stop, "service[#{service_name}]", :before unless (service_name == 'lxd') && old_bridge_is_deleted?
    notifies :start, "service[#{service_name}]", :immediate
    not_if { network_exists? }
  end
  ruby_block 'verify' do
    block do
      raise "Unknown error attempting to rename bridge interface to (#{new_resource.network_name})" unless network_exists?
    end
    action :nothing
    subscribes :run, 'execute[rename]', :immediate
  end
end

action :delete do
  return unless network_exists?
  if new_bridge?
    converge_by "delete LXD network (#{new_resource.network_name})" do
      lxd.exec! "lxc network delete #{new_resource.network_name}" # if there are containers using this network, we'll just let LXD complain about it & pop an error if it wants
    end
  else # not sure what'll happen in this case - probably the inner interfaces withing the containers will go offline.
    # TODO: should I error?  let's test and then replicate the behaviour given by new_bridge
    service_name = node['lsb']['codename'] == 'trusty' ? 'lxd' : 'lxd-bridge'
    service service_name do
      action :enable
    end
    template OLD_BRIDGE_FILE do
      source 'lxd-bridge.erb'
      variables resource: {
        network_name: '',
        use_lxd_bridge: 'false',
      }
      owner 'root'
      group 'root'
      mode '0644'
      action :create
      notifies :stop, "service[#{service_name}]", :before unless (service_name == 'lxd') && old_bridge_is_deleted?
      notifies :start, "service[#{service_name}]", :immediate
    end
  end
end

action_class do
  def lxd
    @lxd ||= Chef::Recipe::LXD.new node, new_resource.server_path
  end

  def info
    @info ||= lxd.info
  end

  def new_bridge?
    info['api_extensions'].index 'network'
  rescue Mixlib::ShellOut::ShellCommandFailed
    # escape clause to allow reconfiguring a borked old-bridge (in which case the lxd service won't start & 'lxc info' won't work)
    raise unless ::File.exist?('/etc/default/lxd-bridge')
    false
  end

  def old_bridge_is_deleted?
    !shell_out("grep 'USE_LXD_BRIDGE=\"false\"' #{OLD_BRIDGE_FILE}").error?
  end

  def key_name(property)
    KEY_OVERRIDES.key?(property.name) ? KEY_OVERRIDES[property.name] : property.name.to_s.tr('_', '.')
  end

  OLD_BRIDGE_FILE = '/etc/default/lxd-bridge'.freeze

  def network_exists?
    return (new_resource.network_name == shell_out!("sed -n '/^LXD_BRIDGE=/s/.*=\"\\(.*\\)\"/\\1/p' #{OLD_BRIDGE_FILE}").stdout.strip) unless new_bridge?

    lxd.exec! "lxc network show #{new_resource.network_name}"
    return true
  rescue Mixlib::ShellOut::ShellCommandFailed
    return false
  end

  def resolve_ipv4(address)
    return nil if address.to_s == 'none'
    return address if address.is_a?(String)
    # at this point address should equal :auto
    return current_resource.ipv4_address if current_resource.ipv4_address.is_a? String

    net = "10.#{Random.rand(255)}.#{Random.rand(254) + 1}."
    # TODO: This collision detection should check all interfaces
    return resolve_ipv4(address) if node['ipaddress'].start_with?(net) # redo upon collision via recursion
    "#{net}1/24"
  end

  def resolve_ipv6(address)
    return nil if address.to_s == 'none'
    return address if address.is_a?(String)
    # at this point address should equal :auto
    return current_resource.ipv6_address if current_resource.ipv6_address.is_a? String

    net = "fd#{Random.rand(256).to_s(16).rjust(2, '0')}:#{Random.rand(65536).to_s(16)}:#{Random.rand(65536).to_s(16)}:#{Random.rand(65536).to_s(16)}:"
    # TODO: This collision detection should check all interfaces
    return resolve_ipv6(address) if node['ip6address'].start_with?(net) # redo upon collision via recursion
    "#{net}:1/64"
  end

  def ipv4_netmask(network)
    return nil unless network
    numbits = network.split('/')[1].to_i
    mask = [1, 1, 1, 1]
    4.times do |part|
      thisbits = numbits > 8 ? 8 : numbits
      numbits -= thisbits
      mask[part] <<= thisbits
      mask[part] -= 1
      mask[part] <<= (8 - thisbits)
    end
    mask.join '.'
  end

  def old_ipv4_dhcp_range(cidr, new_range)
    return new_range unless new_range.to_s == 'auto'
    return nil unless cidr
    # new_range should now be :auto
    address, bits = cidr.split('/', 2)
    raise 'Your IPv4 subnet is too small to automatically generate a DHCP pool.  Specify #ipv4_dhcp_ranges manually, or increase the size of your subnet.' unless bits.to_i < 30
    mask = ipv4_netmask(cidr).split('.').map(&:to_i)
    flip = mask.map { |v| 255 - v }
    host = address.split('.').map(&:to_i)
    net = []
    rstart = []
    rend = []
    4.times do |idx|
      rstart[idx] = net[idx] = host[idx] & mask[idx]
      rend[idx] = net[idx] | flip[idx]
    end

    # is host at start or end of range?  our range has at least 8 (or 6 usable) addresses so there is determistically 2 before or 2 after
    # we can only return one range, so we'll return the range after the host, unless the host is at the end (which is the 'weird' case)
    if  (host[0] == rend[0]) &&
        (host[1] == rend[1]) &&
        (host[2] == rend[2]) &&
        host[3] > (rend[3] - 3) # there need be 2 addresses (plus the broadcast) after the host in order to specify a range after the host
      rend[3] = host[3] - 1 # if not, then range goes before the host
      rstart[3] += 1 # get off the net address
    else
      rstart = host.dup
      rstart[3] += 1 # get off the host
      rend[3] -= 1 # get off the broadcast address
      if rstart[3] >= 255 # the host could be anywhere, so do carry logic (all other math is deduced to not need carries)
        rstart[3] = 1
        rstart[2] += 1
        if rstart[2] == 256
          rstart[2] = 0
          rstart[1] += 1
          if rstart[1] == 256 # rubocop:disable Metrics/BlockNesting
            rstart[1] = 0
            rstart[0] += 1
          end
        end
      end
    end
    "#{rstart.join('.')}-#{rend.join('.')}"
  end

  # the nat settings have a conditional default
  # they're false, unless the ip/network settings are automatically generated
  #   in which case nat will default to true
  # so you'll get a random nat'd network if you leave everything to default/auto
  #   otherwise you have to explicitly enable nat
  def resolve_ipv4_nat(val)
    return false if val == false
    return true if new_resource.ipv4_address == :auto
    val
  end

  def resolve_ipv6_nat(val)
    return false if val == false
    return true if new_resource.ipv6_address == :auto
    val
  end
end

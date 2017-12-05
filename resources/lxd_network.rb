require 'yaml'
require 'pp'

property :network_name, String, name_property: true
property :server_path, String, default: '/var/lib/lxd', identity: true

property :bridge_driver, Symbol, equal_to: [:native, :openvswitch], default: :native
property :bridge_external_interfaces, String, coerce: ->(iface) { iface.is_a?(String) ? iface : iface.join(',') }
property :profiles, Array
property :raw_dnsmasq, String

property :ipv4_address, [String, Symbol], default: :auto, callbacks: {
  'Invalid IPv4 address' => ->(addr) { addr.is_a?(String) || [:auto, :none].include?(addr) },
}
property :ipv4_dhcp, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv4_dhcp_expiry, Integer, default: 60
property :ipv4_dhcp_ranges, String, coerce: ->(range) { range.is_a?(String) ? range : range.join(',') }
property :ipv4_firewall, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv4_nat, [true, false], coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv4_routes, String, coerce: ->(route) { route.is_a?(String) ? route : route.join(',') }
property :ipv4_routing, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }

property :ipv6_address, [String, Symbol], default: :auto, callbacks: {
  'Invalid IPv6 address' => ->(addr) { addr.is_a?(String) || [:auto, :none].include?(addr) },
}
property :ipv6_dhcp, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv6_dhcp_expiry, Integer, default: 60
property :ipv6_dhcp_ranges, String, coerce: ->(range) { range.is_a?(String) ? range : range.join(',') }
property :ipv6_dhcp_stateful, [true, false], default: false, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv6_firewall, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv6_nat, [true, false], coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }
property :ipv6_routes, String, coerce: ->(route) { route.is_a?(String) ? route : route.join(',') }
property :ipv6_routing, [true, false], default: true, coerce: ->(val) { val.is_a?(String) ? val == 'true' : val }

resource_name :lxd_network

load_current_value do
  lxd = Chef::Recipe::LXD.new node, server_path
  # New bridge code
  if lxd.info['api_extensions'].index 'network'
    begin
      net = YAML.load lxd.exec! "lxc network show #{network_name}"
    rescue Mixlib::ShellOut::ShellCommandFailed
      return
    end
    net['config'].each do |k, v|
      prop = k.tr('.', '_')
      call(prop, v) if respond_to? prop
    end
  else # old bridge code
    # network_name `sed -n '/^LXD_BRIDGE=/s/.*="\\(.*\\)"/\\1/p' /etc/default/lxd-bridge`.strip
    ipv4 = {}
    ipv6 = {}
    IO.readlines('/etc/default/lxd-bridge').each do |line|
      val = line[/="(.*)"/, 1]
      next if !val || val.empty?
      case line.split('=')[0].strip
      when 'LXD_BRIDGE' then network_name val
      when 'LXD_CONFILE' then raw_dnsmasq val
      # when 'LXD_DOMAIN="lxd"') then network_name line[/="(.*)"/, 1]
      when 'LXD_IPV4_ADDR' then ipv4[:address] = val
      when 'LXD_IPV4_NETWORK' then ipv4[:mask] = line[%r{=".*/(.*)"}, 1]
      when 'LXD_IPV4_DHCP_RANGE' then ipv4_dhcp_ranges val.tr(',', '-') # only one range supported
      when 'LXD_IPV4_NAT' then ipv4_nat val
      when 'LXD_IPV6_ADDR' then ipv6[:address] = val
      when 'LXD_IPV6_MASK' then ipv6[:mask] = val
      when 'LXD_IPV6_NAT' then ipv6_nat val
      end
      # UPDATE_PROFILE="true"
    end
    ipv4_address "#{ipv4[:address]}/#{ipv4[:mask]}" unless ipv4.empty?
    ipv6_address "#{ipv6[:address]}/#{ipv6[:mask]}" unless ipv6.empty?
  end
end

action :create do
  return action_modify if network_exists?
  raise "The current LXD bridge does not have the same name (#{new_resource.network_name}).  Use the :rename action if this is intended." unless new_bridge?
end

action :modify do
  raise "LXD network (#{network_name}) does not exist." unless network_exists?
  ipv4 = resolve_ipv4(new_resource.ipv4_address)
  ipv6 = resolve_ipv6(new_resource.ipv6_address)
  unless new_bridge?
    template OLD_BRIDGE_FILE do
      source 'lxd-bridge.erb'
      variables resource: {
        network_name: new_resource.network_name,
        raw_dnsmasq: new_resource.raw_dnsmasq,
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
      notifies :restart, 'service[lxd-bridge]', :delayed
    end
    service 'lxd-bridge' do
      action [:enable, :start]
    end
  end
end

# the old lxd ecosystem can only manage one bridge at a time.  We need some way to error if the user tries to set up 2+ bridges
# so in the 'old-way' we'll require the names to match before converging
# so if you want to set up a bridge named other than 'lxdbr0', then include the :rename action first in your recipe
# in the 'new-way' where multiple bridges are allowed, this is a no-op since there is no 'old-name', nor any single source of truth for that name, to rename from

# !!!  There's a USE_LXD_BRIDGE="true" setting saying to re-use or to set up a new one?  do I want to go that far?
#   it would ultimately end up in abandoned bridges(?)  perhaps another setting allowing override(?)

# Deprecated - to be removed when I abandon the 2.0.x branch of LXD
action :rename do
  return if new_bridge?
  unless current_resource.network_name == new_resource.network_name
    converge_by "renaming network to (#{new_resource.network_name})" do
      shell_out! "sed -i '/^LXD_BRIDGE=/s/=\".*\"/=\"#{new_resource.network_name}\"/' #{OLD_BRIDGE_FILE}"
      raise "Unknown error attempting to rename bridge interface to (#{new_resource.network_name})" unless network_exists?
      service 'lxd-bridge' do
        action :restart
      end
    end
  end
end

action :delete do
  return unless network_exists?
  converge_by "deleting LXD network (#{new_resource.network_name})" do
    if new_bridge?
      lxd.exec! "lxc network delete #{network_name}"
    else
      service 'lxd-bridge' do
        action [:stop, :disable]
      end
      return
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
  end

  OLD_BRIDGE_FILE = '/etc/default/lxd-bridge'.freeze

  def network_exists?
    unless new_bridge?
      return new_resource.network_name == shell_out!("sed -n '/^LXD_BRIDGE=/s/.*=\"\\(.*\\)\"/\\1/p' #{OLD_BRIDGE_FILE}").stdout.strip
    end
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

    net = "fd#{Random.rand(255).to_s(16).rjust(2, '0')}:#{Random.rand(65535).to_s(16)}:#{Random.rand(65535).to_s(16)}:#{Random.rand(65535).to_s(16)}:"
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
      thisbits.times { mask[part] *= 2 }
      mask[part] -= 1
      mask[part] << (8 - thisbits)
    end
    mask.join '.'
  end

  def old_ipv4_dhcp_range(cidr, new_range)
    return new_range if new_range
    return nil unless cidr
    mask = ipv4_netmask(cidr).split('.').map(&:to_i)
    flip = mask.map { |v| 255 - v }
    host = cidr.split('/')[0].split('.').map(&:to_i)
    net = []
    rstart = []
    rend = []
    4.times do |idx|
      rstart[idx] = net[idx] = host[idx] & mask[idx]
      rend[idx] = net[idx] | flip[idx]
    end

    # is host at start or end of range?
    # we can only return one range, so we'll return the range after the host, unless the host is at the end
    if  (host[0] == rend[0]) &&
        (host[1] == rend[1]) &&
        (host[2] == rend[2]) &&
        host[3] >= (rend[3] - 3)
      rend[3] = host[3] - 1
      rstart[3] += 1
    else
      rstart = host.dup
      rend[3] -= 1
      rstart[3] += 1
      if rstart[3] >= 255
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
    "#{rstart.join('.')},#{rend.join('.')}"
  end

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

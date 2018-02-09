
class Chef::Recipe::LXD
  module ContainerProperties
    def self.included(resource)
      return unless resource.respond_to? :property
      # return unless resource.is_a? Chef::Mixin::Properties::ClassMethods

      coercions = {
        bool: ->(val) { val == '' ? nil : (val.is_a?(String) ? ((val.downcase == 'true') ? true : false) : val) }, # rubocop:disable Style/NestedTernaryOperator
        int: ->(val) { val == '' ? nil : val.to_i },
        sym: ->(val) { val == '' ? nil : val.to_sym },
      }

      resource.property :boot_autostart, [true, false, nil], coerce: coercions[:bool]
      resource.property :boot_autostart_delay, [Integer, nil], default: 0, coerce: coercions[:int]
      resource.property :boot_autostart_priority, [Integer, nil], default: 0, coerce: coercions[:int]
      resource.property :boot_host_shutdown_timeout, [Integer, nil], default: 30, coerce: coercions[:int]
      resource.property :boot_stop_priority, [Integer, nil], default: 0, coerce: coercions[:int]

      resource.property :environment, [Hash, nil]

      resource.property :limits_cpu, [String, nil]
      resource.property :limits_cpu_allowance, [String, nil]
      resource.property :limits_cpu_priority, [Integer, nil], default: 10, coerce: coercions[:int], callbacks: { 'limits_cpu_priority out of range (0-10)' => ->(val) { (val >= 0) && (val <= 10) } }
      resource.property :limits_disk_priority, [Integer, nil], default: 5, coerce: coercions[:int], callbacks: { 'limits_disk_priority out of range (0-10)' => ->(val) { (val >= 0) && (val <= 10) } }
      resource.property :limits_kernel, [Hash, nil]
      resource.property :limits_memory, [String, nil]
      resource.property :limits_memory_enforce, [:hard, :soft, nil], default: :hard, coerce: coercions[:sym]
      resource.property :limits_memory_swap, [true, false, nil], default: true, coerce: coercions[:bool]
      resource.property :limits_memory_swap_priority, [Integer, nil], default: 10, coerce: coercions[:int], callbacks: { 'limits_memory_swap_priority out of range (0-10)' => ->(val) { (val >= 0) && (val <= 10) } }
      resource.property :limits_network_priority, [Integer, nil], default: 0, coerce: coercions[:int], callbacks: { 'limits_network_priority out of range (0-10)' => ->(val) { (val >= 0) && (val <= 10) } }
      resource.property :limits_processes, [Integer, nil], coerce: coercions[:int]

      resource.property :linux_kernel_modules, [String, nil], coerce: ->(val) { val.is_a? Array ? val.join(',') : val }

      resource.property :migration_incremental_memory, [true, false, nil], default: false, coerce: coercions[:bool]
      resource.property :migration_incremental_memory_goal, [Integer, nil], default: 70, coerce: coercions[:int], callbacks: { 'migration_incremental_memory_goal out of range (0-100)%' => ->(val) { (val >= 0) && (val <= 100) } }
      resource.property :migration_incremental_memory_iterations, [Integer, nil], default: 10, coerce: coercions[:int]

      resource.property :raw_apparmor, [String, nil]
      resource.property :raw_idmap, [String, nil]
      resource.property :raw_lxc, [String, nil]
      resource.property :raw_seccomp, [String, nil]

      resource.property :security_devlxd, [true, false, nil], default: true, coerce: coercions[:bool]
      resource.property :security_idmap_base, [Integer, nil], coerce: coercions[:int]
      resource.property :security_idmap_isolated, [true, false, nil], default: false, coerce: coercions[:bool]
      resource.property :security_idmap_size, [Integer, nil], coerce: coercions[:int]
      resource.property :security_nesting, [true, false, nil], default: false, coerce: coercions[:bool]
      resource.property :security_privileged, [true, false, nil], default: false, coerce: coercions[:bool]
      resource.property :security_syscalls_blacklist, [String, nil]
      resource.property :security_syscalls_blacklist_compat, [true, false, nil], default: false, coerce: coercions[:bool]
      resource.property :security_syscalls_blacklist_default, [true, false, nil], default: true, coerce: coercions[:bool]
      resource.property :security_syscalls_whitelist, [String, nil]

      resource.property :user, [Hash, nil]
    end

    def load_properties(data)
      env = {}
      limits = {}
      usr = {}
      data.each do |key, val|
        val = nil if val == '' # if previously unset, the setting remains in the profile with an empty ''
        propname = key.to_s.tr('.', '_')
        parts = propname.split('_')
        if parts[0] == 'environment'
          env[parts[1..-1].join('_').to_sym] = val
        elsif parts[0] == 'user'
          usr[parts[1..-1].join('_').to_sym] = val
        elsif (parts[0] == 'limits') && (parts[1] == 'kernel')
          limits[parts[2..-1].join('_').to_sym] = val
        else
          send propname, val
        end
      end
      environment env unless env.empty?
      limits_kernel limits unless limits.empty?
      user usr unless usr.empty?
    end

    module ActionHelpers
      KEY_OVERRIDES = {
        boot_host_shutdown_timeout: 'boot.host_shutdown_timeout',
        linux_kernel_modules: 'linux.kernel_modules',
        security_syscalls_blacklist_compat: 'security.syscalls.blacklist_compat',
        security_syscalls_blacklist_default: 'security.syscalls.blacklist_default',
      }.freeze

      EXCLUDE_AUTO_PROPS = [:limits_kernel, :environment, :user].freeze # these come in as hashes and map into the config with custom key names

      def key_name(key)
        return KEY_OVERRIDES[key] if KEY_OVERRIDES.key? key
        key.to_s.tr('_', '.')
      end

      def create_command_args(excludes = [], prefix = ' -c ')
        excludes ||= []
        excludes << EXCLUDE_AUTO_PROPS
        cmd = ''
        new_resource.class.state_properties.each do |prop|
          next if prop.identity? || prop.name_property?
          next if excludes.include? prop.name
          converge_if_changed prop.name do
            val = new_resource.send(prop.name)
            cmd << prefix << "#{key_name(prop.name)}='#{val}'"
          end
        end
        cmd << converge_hash(:environment, nil, nil, prefix)
        cmd << converge_hash(:limits_kernel, nil, nil, prefix)
        cmd << converge_hash(:user, nil, nil, prefix)

        cmd
      end

      # the profile doesn't have a create command that accepts all args (according to cli --help), so create & modify will pass through this function
      # this does each setting line by line (multiple execs)
      #   I may want to pile it into a single YAML and shove it in
      #     but I have reservations re: simplicity of convergence - this is harder on lxc with multiple execs, but easier for me with simpler functions
      #       I 'predict' someday there may be some settings happen (with alphabetical/key_order issues?) that rely on other settings being set first
      #         If that happens then prepare to adopt the single YAML method (e.g. `dumpsettings > tmpfile && cat tmpfile | lxc profile edit blah ...` )
      #         or some such
      def modify_properties(scope, name, excludes = [])
        setcmd = "lxc #{scope} set #{name} "
        unsetcmd = "lxc #{scope} unset #{name} "
        excludes ||= []
        excludes += EXCLUDE_AUTO_PROPS
        new_resource.class.state_properties.each do |prop|
          next if prop.identity? || prop.name_property?
          next if excludes.include? prop.name
          converge_if_changed prop.name do
            val = new_resource.send(prop.name)
            val.nil? ? lxd.exec!(unsetcmd + key_name(prop.name)) : lxd.exec!(setcmd + "#{key_name(prop.name)} '#{val}'")
          end
        end

        converge_hash :environment, scope, name
        converge_hash :limits_kernel, scope, name
        converge_hash :user, scope, name
      end

      def converge_hash(hash_key, scope, name, create_prefix = nil)
        setcmd = "lxc #{scope} set #{name} "
        unsetcmd = "lxc #{scope} unset #{name} "
        retval = ''
        unless !current_resource.send(hash_key) && new_resource.send(hash_key) && (new_resource.send(hash_key).empty? || all_nil?(new_resource.send(hash_key)))
          if new_resource.send(hash_key)
            new_resource.send(hash_key).each do |key, val|
              next if val.nil? && !current_resource.send(hash_key) # next if nil && wasn't previously set
              next if current_resource.send(hash_key) && (val == current_resource.send(hash_key)[key]) # next if new == current (i.e. not the reason we're converging)
              keyname = "#{key_name(hash_key)}.#{key}"
              if create_prefix
                retval << create_prefix + "#{keyname}='#{val}'"
              else
                converge_by "set #{hash_key} key #{key}" do
                  val.nil? ? lxd.exec!(unsetcmd + keyname) : lxd.exec!(setcmd + "#{keyname} '#{val}'") # rubocop:disable Metrics/BlockNesting
                end
              end
            end
          elsif !create_prefix && property_is_set?(hash_key) && current_resource.send(hash_key) # hash was set to nil in the recipe, but we have settings to unset
            current_resource.send(hash_key).each do |key, val|
              next if val.nil?
              keyname = "#{hash_key.to_s.tr('_', '.')}.#{key}"
              converge_by "clear #{hash_key} key #{key}" do
                lxd.exec!(unsetcmd + keyname)
              end
            end
          end
        end
        retval
      end

      def all_nil?(hash)
        hash.each do |_, v|
          return false unless v.nil?
        end
        true
      end
    end
  end
end

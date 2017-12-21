class Chef::Recipe::LXD
  module Mixin
    def lxd
      @lxd ||= Chef::Recipe::LXD.new node, server_path
    end

    def info
      @info ||= lxd.info
    end
  end

  module ActionMixin
    def lxd
      @lxd ||= Chef::Recipe::LXD.new node, new_resource.server_path
    end

    def info
      @info ||= lxd.info
    end
  end
end

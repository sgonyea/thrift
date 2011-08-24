# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "thrift/version"

Gem::Specification.new do |s|
  s.name        = 'thrift'
  s.version     = Thrift::VERSION
  s.authors     = ['Thrift Developers']
  s.email       = ['dev@thrift.apache.org']
  s.homepage    = 'http://thrift.apache.org'
  s.summary     = %q{Ruby bindings for Apache Thrift}
  s.description = %q{Ruby bindings for the Apache Thrift RPC system}

  s.extensions = ['ext/extconf.rb']

  s.has_rdoc = true
  s.extra_rdoc_files  = %w[CHANGELOG README ext/binary_protocol_accelerated.c ext/binary_protocol_accelerated.h ext/compact_protocol.c ext/compact_protocol.h ext/constants.h ext/extconf.rb ext/macros.h ext/memory_buffer.c ext/memory_buffer.h ext/protocol.c ext/protocol.h ext/struct.c ext/struct.h ext/thrift_native.c lib/thrift.rb lib/thrift/client.rb lib/thrift/core_ext.rb lib/thrift/exceptions.rb lib/thrift/processor.rb lib/thrift/struct.rb lib/thrift/struct_union.rb lib/thrift/union.rb lib/thrift/thrift_native.rb lib/thrift/types.rb lib/thrift/core_ext/fixnum.rb lib/thrift/protocol/base_protocol.rb lib/thrift/protocol/binary_protocol.rb lib/thrift/protocol/binary_protocol_accelerated.rb lib/thrift/protocol/compact_protocol.rb lib/thrift/serializer/deserializer.rb lib/thrift/serializer/serializer.rb lib/thrift/server/base_server.rb lib/thrift/server/mongrel_http_server.rb lib/thrift/server/nonblocking_server.rb lib/thrift/server/simple_server.rb lib/thrift/server/thread_pool_server.rb lib/thrift/server/threaded_server.rb lib/thrift/transport/base_server_transport.rb lib/thrift/transport/base_transport.rb lib/thrift/transport/buffered_transport.rb lib/thrift/transport/framed_transport.rb lib/thrift/transport/http_client_transport.rb lib/thrift/transport/io_stream_transport.rb lib/thrift/transport/memory_buffer_transport.rb lib/thrift/transport/server_socket.rb lib/thrift/transport/socket.rb lib/thrift/transport/unix_server_socket.rb lib/thrift/transport/unix_socket.rb]
  s.rdoc_options      = %w[--line-numbers --inline-source --title Thrift --main README]

  s.rubyforge_project = 'thrift'

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = %w[lib ext]

  # specify any dependencies here; for example:
  # s.add_runtime_dependency "rest-client"

  s.add_development_dependency "rake"
  s.add_development_dependency "rspec"
  s.add_development_dependency "srv"
end

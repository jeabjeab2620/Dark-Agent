module Dark::ELF::Callbacks
  extend self

  @@xstat_ptr = Pointer(Void).null
  @@lxstat_ptr = Pointer(Void).null
  @@fxstat_ptr = Pointer(Void).null

  # Version argument for the __xstat family. glibc's stat functions take a
  # leading ABI-version argument that varies per architecture:
  #   x86_64  -> _STAT_VER = 1
  #   aarch64 -> _STAT_VER = 0 (generic 64-bit ABI, kernel struct layout)
  # Passing the wrong value makes glibc misinterpret struct stat.
  {% if flag?(:x86_64) %}
  STAT_VER = 1
  {% else %}
  STAT_VER = 0
  {% end %}

  # On glibc < 2.33, stat/lstat/fstat are not exported as binary symbols.
  # The source-level names are macros that redirect to __xstat/__lxstat/__fxstat
  # at compile time. BOFs referencing "stat" need this registered so
  # resolve_symbol finds it before falling through to dlsym (which returns nil).
  #
  # Darwin exports real stat/lstat/fstat symbols, so no shim is needed there.
  {% if flag?(:darwin) %}
  def register_libc_shims
    # No-op: Darwin libc exports stat/lstat/fstat directly and dlsym resolves them.
  end
  {% else %}
  def register_libc_shims
    if xstat_ptr = LibC.dlsym(nil, "__xstat")
      @@xstat_ptr = xstat_ptr
      # Must not capture any local var: a capturing proc is a closure
      # {code_ptr, closure_data_ptr}, and .pointer.address below only
      # keeps code_ptr - the JIT'd BOF then calls raw code expecting a
      # closure_data it never receives, deref'ing garbage/null. Reading
      # @@xstat_ptr (module state) instead keeps this proc non-capturing.
      callback = ->(path : UInt8*, buf : Void*) {
        fn = Proc(Int32, Int32, UInt8*, Void*, Int32).new(@@xstat_ptr, Pointer(Void).null)
        fn.call(STAT_VER, path, buf)
      }
      register("stat", callback.pointer.address)
    end

    if lxstat_ptr = LibC.dlsym(nil, "__lxstat")
      @@lxstat_ptr = lxstat_ptr
      callback = ->(path : UInt8*, buf : Void*) {
        fn = Proc(Int32, Int32, UInt8*, Void*, Int32).new(@@lxstat_ptr, Pointer(Void).null)
        fn.call(STAT_VER, path, buf)
      }
      register("lstat", callback.pointer.address)
    end

    if fxstat_ptr = LibC.dlsym(nil, "__fxstat")
      @@fxstat_ptr = fxstat_ptr
      # __fxstat takes a file descriptor instead of a path.
      callback = ->(fd : Int32, buf : Void*) {
        fn = Proc(Int32, Int32, Int32, Void*, Int32).new(@@fxstat_ptr, Pointer(Void).null)
        fn.call(STAT_VER, fd, buf)
      }
      register("fstat", callback.pointer.address)
    end
  end
  {% end %}
end

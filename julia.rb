require 'formula'

class GitNoDepthDownloadStrategy < GitDownloadStrategy
  # We need the .git folder for it's information, so we clone the whole thing
  # We also want to avoid downloading all the submodules, so we clone those explicitly
  def stage
    dst = Dir.getwd
    @clone.cd do
      reset
      safe_system 'git', 'clone', '.', dst
      # Get the deps/ submodules
      if head?
        deps = []
      else
        deps = ["Rmath", "libuv", "openlibm"]
      end
      deps.each do |subm|
        safe_system 'git', 'clone', "deps/#{subm}", "#{dst}/deps/#{subm}"
      end
    end
  end
end

class Julia < Formula
  homepage 'http://julialang.org'

  stable do
    url 'https://github.com/JuliaLang/julia.git',
      :using => GitNoDepthDownloadStrategy, :shallow => false, :tag => 'v0.3.8'
    version '0.3.8'

    # Need suite-sparse 4.2.X on stable branch
    depends_on "staticfloat/julia/suite-sparse42-julia"
  end

  head do
    url 'https://github.com/JuliaLang/julia.git',
      :using => GitNoDepthDownloadStrategy, :shallow => false
    depends_on "libgit2"
    depends_on "staticfloat/julia/suite-sparse-julia"
  end

  bottle do
    root_url 'https://juliabottles.s3.amazonaws.com'
    # Remember to clear "revision" above when prepping for new bottles, if it exists
    sha256 "cb15618a9b76656a8f7f999113377db9d465ee6dec8b7dc6180c29f2cd5379f9" => :yosemite
    sha256 "41aa63230bd5956b34fe2d2115a6ad681811c36258e463da3e44fa627b32b3e0" => :mavericks
    sha256 "149d91275d469b35aa57e2833203d40d2b6b2410ad84abcfd0e86bcdf78002f0" => :mountain_lion
  end

  depends_on "staticfloat/julia/llvm33-julia"
  depends_on "pcre"
  depends_on "gmp"
  depends_on "fftw"
  depends_on :fortran
  depends_on "mpfr"

  # We have our custom formulae of arpack and openblas
  depends_on "staticfloat/julia/arpack-julia"
  depends_on "staticfloat/julia/openblas-julia"

  # Need this as Julia's build process is quite messy with respect to env variables
  env :std

  # Options that can be passed to the build process
  option "build-debug", "Builds julia with debugging information included"
  option "system-libm", "Use system's libm instead of openlibm"

  # Here we build up a list of patches to be applied
  def patches
    patch_list = []

    # First patch fixes hardcoded paths to deps in deps/Makefile
    patch_list << "https://gist.github.com/staticfloat/3806093/raw/cb34c7262b9130f0e9e07641a66fccaa0d08b5d2/deps.Makefile.diff"

    return patch_list
  end

  def install
    ENV['PLATFORM'] = 'darwin'
    ENV['PYTHONPATH'] = ""

    # Build up list of build options
    build_opts = ["prefix=#{prefix}"]
    build_opts << "USE_BLAS64=0"

    # Tell julia about our gfortran
    # (this enables use of gfortran-4.7 from the tap homebrew-dupes/gcc.rb)
    if ENV.has_key? 'FC'
      build_opts << "FC=#{ENV['FC']}"
    end

    # Tell julia about our llc, since it's been named nonstandardly
    build_opts << "LLVM_CONFIG=llvm-config-3.3"

    # Make sure we have space to muck around with RPATHS
    ENV['LDFLAGS'] += " -headerpad_max_install_names"

    # Make sure Julia uses clang if the environment supports it
    build_opts << "USECLANG=1" if ENV.compiler == :clang
    build_opts << "VERBOSE=1" if ARGV.verbose?

    build_opts << "LIBBLAS=-lopenblas"
    build_opts << "LIBBLASNAME=libopenblas"
    build_opts << "LIBLAPACK=-lopenblas"
    build_opts << "LIBLAPACKNAME=libopenblas"

    # Kudos to @ijt for these lines of code
    ['FFTW', 'GLPK', 'GMP', 'LLVM', 'PCRE', 'BLAS', 'LAPACK', 'SUITESPARSE', 'ARPACK', 'MPFR', 'LIBGIT2'].each do |dep|
      build_opts << "USE_SYSTEM_#{dep}=1"
    end

    build_opts << "USE_SYSTEM_LIBM=1" if build.include? "system-libm"

    # If we're building a bottle, cut back on fancy CPU instructions
    build_opts << "MARCH=core2" if build.bottle?

    # call makefile to grab suitesparse libraries
    system "make", "-C", "contrib", "-f", "repackage_system_suitesparse4.make", *build_opts

    # Sneak in the fftw libraries, as julia doesn't know how to load dylibs from any place other than
    # julia's usr/lib directory and system default paths yet; the build process fixes that after the
    # install step, but the bootstrapping process requires the use of the fftw libraries before then
    ['', 'f', '_threads', 'f_threads'].each do |ext|
      ln_s "#{Formula['fftw'].lib}/libfftw3#{ext}.dylib", "usr/lib/"
    end
    # Do the same for openblas, pcre, mpfr, and gmp
    ln_s "#{Formula['openblas-julia'].opt_lib}/libopenblas.dylib", "usr/lib/"
    ln_s "#{Formula['arpack-julia'].opt_lib}/libarpack.dylib", "usr/lib/"
    ln_s "#{Formula['suite-sparse-julia'].opt_lib}/libsuitesparse.dylib", "usr/lib/"
    ln_s "#{Formula['pcre'].lib}/libpcre.dylib", "usr/lib/"
    ln_s "#{Formula['mpfr'].lib}/libmpfr.dylib", "usr/lib/"
    ln_s "#{Formula['gmp'].lib}/libgmp.dylib", "usr/lib/"

    # call make with the build options
    target = "release"
    if build.include? "build-debug"
      target = "debug"
      ohai "Making debug build"
    end

    build_opts << target
    system "make", *build_opts
    build_opts.pop

    # Remove the fftw symlinks again, so we don't have conflicts when installing julia
    ['', 'f', '_threads', 'f_threads'].each do |ext|
      rm "usr/lib/libfftw3#{ext}.dylib"
    end
    rm "usr/lib/libopenblas.dylib"
    rm "usr/lib/libpcre.dylib"
    rm "usr/lib/libmpfr.dylib"
    rm "usr/lib/libgmp.dylib"

    # Install!
    build_opts << "install"
    system "make", *build_opts

    # Add in rpaths into the julia executables so that they can find the homebrew lib folder,
    # as well as any keg-only libraries that they need.
    rpaths = []

    # Add in each formula to the rpaths list
    ['arpack-julia', 'suite-sparse-julia', 'openblas-julia'].each do |formula|
      rpaths << "#{Formula[formula].opt_lib}"
    end

    # Add in generic Homebrew and system paths
    rpaths << "#{HOMEBREW_PREFIX}/lib"

    # Only add this in if we're < 10.8, because after that libxstub makes our lives miserable
    if MacOS.version < :mountain_lion
      rpaths << "/usr/X11/lib"
    end

    # Add those rpaths to the binaries
    rpaths.each do |rpath|
      Dir["#{bin}/julia*"].each do |file|
        quiet_system "install_name_tool", "-add_rpath", rpath, file
      end
    end

    # copy over suite-sparse shlibs manually, pending discussion in https://github.com/JuliaLang/julia/commit/077c63a7164e270970de16863c7575c808a0c756#commitcomment-4128441
    ["spqr", "umfpack", "colamd", "cholmod", "amd", "suitesparse_wrapper"].each do |f|
      (lib + 'julia/').install "usr/lib/lib#{f}.dylib"
    end
  end

  def post_install
    # Change the permissions of lib/julia/sys.* so that build_sysimg.jl can edit them
    Dir["#{lib}/julia/sys.*"].each do |file|
      chmod 0644, file
    end
  end

  def test
    # Run julia-provided test suite, copied over in install step
    if not (share + 'julia/test').exist?
      err = "Could not find test files directory\n"
      if build.head?
        err << "Did you accidentally include --HEAD in the test invocation?"
      else
        err << "Did you mean to include --HEAD in the test invocation?"
      end
      opoo err
    else
      system "#{bin}/julia", "-e", "Base.runtests(\"core\")"
    end
  end

  def caveats
    head_flag = build.head? ? " --HEAD " : " "
    <<-EOS.undent
    Documentation and Examples have been installed into:
    #{share}/julia

    Test suite has been installed into:
    #{share}/julia/test

    To perform a quick sanity check, run the command:
    brew test#{head_flag}-v julia

    To crunch through the full test suite, run the command:
    #{bin}/julia -e "Base.runtests()"
    EOS
  end
end

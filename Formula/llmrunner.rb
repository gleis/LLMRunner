class Llmrunner < Formula
  desc "Local OpenAI-compatible GGUF model server for macOS"
  homepage "https://github.com/gleis/LLMRunner"
  url "https://github.com/gleis/LLMRunner/archive/648a2e4e5ab49ef2b66c20373a96f81f2a7bc812.tar.gz"
  version "0.1.0"
  sha256 "b426192f87898d7f015c16aee7c2295c15f2b73438395ee9cba3b92aa13c79c6"
  license "MIT"

  depends_on "cmake" => :build
  depends_on "pkgconf" => :build
  depends_on :macos
  depends_on macos: :sonoma

  resource "llama" do
    url "https://github.com/ggml-org/llama.cpp/archive/cd959bae99ff4bed22bef2604f45241c09bbb8c8.tar.gz"
    sha256 "fbe74146a3cdc00f706773eb233bc4aedb7d8c3c7e2122440e492a99c1ec5a76"
  end

  def install
    resource("llama").stage do
      system "cmake", "-S", ".", "-B", "build", "-DCMAKE_BUILD_TYPE=Release",
             "-DCMAKE_INSTALL_PREFIX=#{libexec}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
             "-DGGML_NATIVE=OFF", "-DLLAMA_OPENSSL=OFF", "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_EXAMPLES=OFF",
             "-DLLAMA_BUILD_SERVER=ON"
      system "cmake", "--build", "build", "--parallel"
      system "cmake", "--install", "build"
    end
    system "install_name_tool", "-add_rpath", "@executable_path/../lib", libexec/"bin/llama-server"
    Dir[libexec/"lib/*.dylib"].each do |library|
      next if File.symlink?(library)

      system "install_name_tool", "-add_rpath", "@loader_path", library
    end
    ENV["PKG_CONFIG_PATH"] = "#{libexec}/lib/pkgconfig"
    ENV["LLMRUNNER_LIBRARY_PATH"] = "#{opt_libexec}/lib"
    system "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin.install ".build/release/llmrunner" => "llmrunner-bin"
    (bin/"llmrunner").write <<~SH
      #!/bin/bash
      export PATH="#{opt_libexec}/bin:$PATH"
      exec "#{opt_bin}/llmrunner-bin" "$@"
    SH
  end

  test do
    assert_match "llmrunner", shell_output("#{bin}/llmrunner help")
  end
end

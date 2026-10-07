# Template for Formula/duoctl.rb in skarol/homebrew-tap.
# The release workflow fills in url and sha256 and publishes it there.
class Duoctl < Formula
  desc "Fold, rotate and tap the iPhone Duo simulator from the command line"
  homepage "https://github.com/skarol/duoctl"
  url "https://github.com/skarol/duoctl/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACED_BY_RELEASE_WORKFLOW"
  license "MIT"

  depends_on :macos

  def install
    libexec.install Dir["skills/duoctl/scripts/*"]
    bin.install_symlink libexec/"duoctl"
  end

  def caveats
    <<~EOS
      duoctl needs Xcode 27.1 or later with a booted iPhone Duo simulator.
      The first run compiles a small helper with Xcode's clang and caches it in ~/.cache/duoctl.
      --label, --id and `duoctl elements` also need AXe: brew install cameroncooke/axe/axe
    EOS
  end

  test do
    assert_equal "duoctl #{version}", shell_output("#{bin}/duoctl --version").strip
  end
end

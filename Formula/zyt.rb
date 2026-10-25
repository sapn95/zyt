# frozen_string_literal: true

# The formula a release carries with it. Nobody installs from this file:
# `brew install sapn95/tap/zyt` reads the copy in sapn95/homebrew-tap, and that
# tap builds its copy by taking this body out of the newest release's own
# tarball and rewriting the url and the checksum from the file it actually
# downloaded. So this is the place to change what gets installed, and the two
# release lines here are allowed to trail the newest tag by one.
class Zyt < Formula
  desc "Work or private: a Hammerspoon time tracker that knows the difference"
  homepage "https://github.com/sapn95/zyt"
  license "MIT"
  head "https://github.com/sapn95/zyt.git", branch: "main"

  depends_on :macos

  def install
    # The Spoon cannot be linked into ~/.hammerspoon from here: a formula must
    # not write to a home directory. `zyt link` is the step that does.
    libexec.install "Zyt.spoon"
    bin.install "scripts/zyt"
  end

  def caveats
    <<~CAVEATS
      Link the Spoon into Hammerspoon and add the line it prints to
      ~/.hammerspoon/init.lua:

        zyt link

      Then write ~/.config/zyt/rules.json (examples/rules.json in the
      repository is a start), reload Hammerspoon, and check the result:

        zyt doctor
    CAVEATS
  end

  test do
    assert_predicate libexec/"Zyt.spoon/init.lua", :exist?
    assert_match "usage:", shell_output("#{bin}/zyt 2>&1", 2)
  end
end

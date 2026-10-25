# frozen_string_literal: true

# This is the formula; sapn95/homebrew-tap carries a copy of it so that
# `brew install --HEAD sapn95/tap/zyt` works beside the other tools. A change
# here has to be copied there by hand, which is the price of the shorter
# install line.
#
# There is no `url` and no `sha256`: nothing is tagged, and a formula with no
# tag in its urls is one the tap's hourly updater skips rather than rewrites.
# A release would mean both lines here, and then the updater keeps the tap's
# copy current by itself.
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

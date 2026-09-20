# frozen_string_literal: true

# The formula lives in the repository it builds, the same way sapn95/vpnbar does
# it: `brew tap sapn95/zyt <url>` taps this repository directly, so there is one
# place to change and no second repository to keep in step.
class Zyt < Formula
  desc "Work or private: a Hammerspoon time tracker that knows the difference"
  homepage "https://github.com/sapn95/zyt"
  # While the repository is private this is the SSH form, and note the `ssh://`:
  # Homebrew parses it with URI and rejects `git@github.com:...` outright, even
  # though `brew tap` accepts either spelling. Switch to
  # https://github.com/sapn95/zyt.git when the repository goes public.
  head "ssh://git@github.com/sapn95/zyt.git", branch: "main"

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

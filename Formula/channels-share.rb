class ChannelsShare < Formula
  desc "Share a Channels DVR channel as a temporary, private HTTPS link"
  homepage "https://github.com/colemccarren/homebrew-channels-share"
  url "https://github.com/colemccarren/homebrew-channels-share/archive/refs/tags/v0.3.tar.gz"
  version "0.3"
  sha256 "f73c6e329a0f90b134fda9ceaffc00be2590aaf493e80de09181ade3b671a8b4"
  license "MIT"

  depends_on "bash"
  depends_on "cloudflared"
  depends_on "ffmpeg"
  depends_on "python@3"

  def install
    bin.install "channels-share.sh" => "channels-share"
  end

  test do
    system "#{bin}/channels-share", "--help"
  end
end

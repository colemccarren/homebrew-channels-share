class ChannelsShare < Formula
  desc "Share a Channels DVR channel as a temporary, private HTTPS link"
  homepage "https://github.com/colemccarren/homebrew-channels-share"
  url "https://github.com/colemccarren/homebrew-channels-share/archive/refs/tags/v0.2.tar.gz"
  version "0.2"
  sha256 "e4f54cd7526a20acbad110b15a01e2ae1eb0e4d28274b04c219b287c85d8ea14"
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

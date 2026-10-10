using System.Globalization;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>The HEVC encoder a picture tier is made with.</summary>
public enum TierEncoder
{
    /// <summary>Apple's hardware encoder (a Mac server's jellyfin-ffmpeg).</summary>
    VideoToolbox,
    /// <summary>Software, anywhere else.</summary>
    X265
}

/// <summary>The transfer function a tier keeps from its source.</summary>
public enum TierTransfer
{
    Sdr,
    Pq,
    Hlg
}

/// <summary>
/// The decisions behind the lower picture tiers (VideoSegmentService), kept
/// apart from the processes and Jellyfin services so TierPlanningCheck can
/// run them alone.
///
/// A tier is named by its height and fits a 16:9 box of that height
/// (1440: 2560×1440, 1080: 1920×1080), so a scope film (3840×1600) at 1080
/// is 1920×800, not 2592×1080. Each tier is cut on the original's own
/// keyframe index: segment n of every tier covers the same film time, and a
/// client can change tier at any segment.
/// </summary>
public static class VideoTiers
{
    /// <summary>Every tier a client may ask for, largest first.</summary>
    public static readonly IReadOnlyList<int> Heights = [1440, 1080];

    /// <summary>
    /// A frame's worth less than the indexed start: a forced keyframe lands
    /// on the first frame at or after its time, and the Cues round a
    /// keyframe's time by a millisecond or two either way (Baby Driver's
    /// segment 1893 is indexed 2 ms after it presents). Under half a frame at
    /// 60 fps, so the frame before is never the one forced.
    /// </summary>
    public const double KeyframeLeadSeconds = 0.008;

    public static bool IsTier(int height) => Heights.Contains(height);

    /// <summary>The width of the tier's 16:9 box.</summary>
    public static int BoxWidth(int height) => height * 16 / 9;

    /// <summary>
    /// The average bitrate of a tier. Roughly what streaming services give
    /// HDR HEVC at these sizes: 24 Mbps at 1440, 14 Mbps at 1080. A UHD remux
    /// is 50-90 Mbps.
    /// </summary>
    public static int BitsPerSecond(int height) => height >= 1440 ? 24_000_000 : 14_000_000;

    /// <summary>
    /// The transfer a transcode keeps, or null when the picture can't be
    /// transcoded faithfully: Dolby Vision without an HDR10, HLG or SDR base
    /// (profile 5's IPT-PQ-C2 decodes to the wrong colours without its RPU).
    /// </summary>
    public static TierTransfer? Transfer(string videoRange, int? dvProfile)
    {
        var range = videoRange ?? string.Empty;
        if (dvProfile == 5 || string.Equals(range, "DOVI", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        if (range.Contains("HLG", StringComparison.OrdinalIgnoreCase))
        {
            return TierTransfer.Hlg;
        }

        // HDR10, HDR10Plus, DOVIWithHDR10, DOVIWithEL (profile 7's base is HDR10).
        if (range.Contains("HDR10", StringComparison.OrdinalIgnoreCase)
            || range.Contains("DOVIWithEL", StringComparison.OrdinalIgnoreCase))
        {
            return TierTransfer.Pq;
        }

        return TierTransfer.Sdr;
    }

    /// <summary>
    /// The tiers offered for a source, largest first: those whose box is
    /// smaller than the picture in either dimension. A 3840×2160 source
    /// gets [1440, 1080], 2560×1440 gets [1080], 1920×1080 none.
    /// </summary>
    public static List<int> Offered(int? width, int? height, string videoRange, int? dvProfile)
    {
        if (width is not int w || height is not int h || w <= 0 || h <= 0 || Transfer(videoRange, dvProfile) is null)
        {
            return [];
        }

        return Heights.Where(t => w > BoxWidth(t) || h > t).ToList();
    }

    /// <summary>
    /// The times to force keyframes at in a run over segments
    /// <paramref name="first"/>..<paramref name="last"/>: each segment's
    /// start from <paramref name="first"/> to the one after
    /// <paramref name="last"/> (where ffmpeg stops), less
    /// <see cref="KeyframeLeadSeconds"/>, in film time. A run keeps the
    /// film's timestamps (-copyts), so film time is its output timeline too.
    ///
    /// ffmpeg takes at most one listed time per frame, so nothing may be
    /// listed before the run's first frame but the first segment's own
    /// start: the seek lands on that segment's keyframe, which then takes it
    /// (already a keyframe), or one interval early (Cues), where the list
    /// starting at <paramref name="first"/> still forces every keyframe the
    /// copy would have.
    /// </summary>
    public static List<double> ForcedKeyframes(IReadOnlyList<double> starts, int first, int last)
    {
        var times = new List<double>();
        for (var n = Math.Max(0, first); n <= last + 1 && n < starts.Count; n++)
        {
            times.Add(Math.Max(0, starts[n] - KeyframeLeadSeconds));
        }

        return times;
    }

    /// <summary>
    /// ffmpeg's output arguments for a tier, between the input's mapping and
    /// the HLS muxer: scale into the tier's box, 10-bit HEVC (hvc1) at the
    /// tier's bitrate, keyframes only where forced, the source's colour tags.
    /// Dolby Vision is not carried (no RPU, no dvcC): the result is the
    /// base layer's HDR10, HLG or SDR. No audio.
    /// </summary>
    public static List<string> EncodeArguments(TierEncoder encoder, int height, TierTransfer transfer, IReadOnlyList<double> keyframes)
    {
        var bitrate = BitsPerSecond(height);
        var pixelFormat = encoder == TierEncoder.VideoToolbox ? "p010le" : "yuv420p10le";
        var args = new List<string>
        {
            "-vf", $"scale=w={BoxWidth(height)}:h={height}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=bicubic,format={pixelFormat}",
            // Every source frame once, at its own time: a frame dropped or
            // duplicated to a constant rate would move the keyframes.
            "-fps_mode", "passthrough",
            "-force_key_frames", string.Join(",", keyframes.Select(t => t.ToString("F3", CultureInfo.InvariantCulture))),
            // No encoder-chosen keyframes: the HLS muxer splits at every one,
            // and a segment is one index interval.
            "-g", "100000",
            "-b:v", bitrate.ToString(CultureInfo.InvariantCulture),
            "-maxrate", (bitrate * 3 / 2).ToString(CultureInfo.InvariantCulture),
            "-bufsize", (bitrate * 2).ToString(CultureInfo.InvariantCulture),
        };
        if (encoder == TierEncoder.VideoToolbox)
        {
            args.AddRange(["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-realtime", "0"]);
        }
        else
        {
            var x265 = "scenecut=0:open-gop=0:log-level=error";
            if (transfer != TierTransfer.Sdr)
            {
                // The mastering display and light level ride along from the
                // decoded frames' side data; this writes them as SEI.
                x265 += ":hdr10=1:hdr10-opt=0";
            }

            args.AddRange(["-c:v", "libx265", "-preset", "veryfast", "-profile:v", "main10",
                "-forced-idr", "1", "-dolbyvision", "0", "-x265-params", x265]);
        }

        args.AddRange(transfer switch
        {
            TierTransfer.Pq => new[] { "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc" },
            TierTransfer.Hlg => ["-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc"],
            _ => []
        });
        args.AddRange(["-tag:v", "hvc1", "-an", "-sn", "-dn"]);
        return args;
    }

    /// <summary>
    /// The encoder for a tier, from <c>ffmpeg -hide_banner -encoders</c>'s
    /// listing: VideoToolbox when it is built in, else libx265; null with
    /// neither.
    /// </summary>
    public static TierEncoder? PickEncoder(string encodersListing)
    {
        static bool Lists(string listing, string name) => listing.Split('\n')
            .Any(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries) is { Length: >= 2 } parts && parts[1] == name);

        if (Lists(encodersListing, "hevc_videotoolbox"))
        {
            return TierEncoder.VideoToolbox;
        }

        return Lists(encodersListing, "libx265") ? TierEncoder.X265 : null;
    }
}

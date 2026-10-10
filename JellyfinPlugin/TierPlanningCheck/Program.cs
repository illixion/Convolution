using Jellyfin.Plugin.AtmosObjects;

if (args.Length == 5 && args[0] == "args")
{
    var grid = Enumerable.Range(0, 10000).Select(i => (double)i).ToList();
    var encoder = args[1] == "videotoolbox" ? TierEncoder.VideoToolbox : TierEncoder.X265;
    var tierArgs = VideoTiers.EncodeArguments(encoder, int.Parse(args[2]), TierTransfer.Pq,
        VideoTiers.ForcedKeyframes(grid, int.Parse(args[3]), int.Parse(args[4])));
    Console.WriteLine(string.Join("\n", tierArgs));
    return 0;
}

int fails = 0, checks = 0;
void Check(bool ok, string what) { checks++; if (!ok) { fails++; Console.WriteLine("FAIL: " + what); } else Console.WriteLine("ok:   " + what); }
string Show(IEnumerable<int> list) => "[" + string.Join(",", list) + "]";

// 1. Which tiers a source gets: those whose 16:9 box is smaller in either dimension.
Check(Show(VideoTiers.Offered(3840, 2160, "HDR10", null)) == "[1440,1080]", "UHD gets 1440 and 1080");
Check(Show(VideoTiers.Offered(3840, 1600, "DOVIWithHDR10", 8)) == "[1440,1080]", "a scope UHD film gets both (wider than either box)");
Check(Show(VideoTiers.Offered(2560, 1440, "SDR", null)) == "[1080]", "1440p gets 1080 only");
Check(Show(VideoTiers.Offered(1920, 1080, "HDR10", null)) == "[]", "1080p gets none");
Check(Show(VideoTiers.Offered(1920, 800, "SDR", null)) == "[]", "a scope 1080p film gets none");
Check(Show(VideoTiers.Offered(2048, 858, "SDR", null)) == "[1080]", "a 2K DCP-width film is wider than 1920: 1080");
Check(Show(VideoTiers.Offered(3840, 2160, "DOVI", 5)) == "[]", "Dolby Vision profile 5 (no HDR10 base) gets none without a reshape");
Check(Show(VideoTiers.Offered(3840, 1740, "DOVI", 5, canReshape: true)) == "[1440,1080]", "profile 5 gets both when its RPU can be applied");
Check(Show(VideoTiers.Offered(3840, 2160, "DOVIWithEL", 7)) == "[1440,1080]", "profile 7 keeps its HDR10 base: both");
Check(Show(VideoTiers.Offered(null, 2160, "HDR10", null)) == "[]" && Show(VideoTiers.Offered(3840, 0, "HDR10", null)) == "[]",
    "unknown dimensions get none");

// 2. Transfer kept.
Check(VideoTiers.Transfer("HDR10", null) == TierTransfer.Pq && VideoTiers.Transfer("HDR10Plus", null) == TierTransfer.Pq
      && VideoTiers.Transfer("DOVIWithHDR10", 8) == TierTransfer.Pq, "HDR10, HDR10+ and DV 8.1 keep PQ");
Check(VideoTiers.Transfer("HLG", null) == TierTransfer.Hlg && VideoTiers.Transfer("DOVIWithHLG", 8) == TierTransfer.Hlg, "HLG keeps HLG");
Check(VideoTiers.Transfer("SDR", null) == TierTransfer.Sdr && VideoTiers.Transfer("DOVIWithSDR", 8) == TierTransfer.Sdr, "SDR stays SDR");
Check(VideoTiers.Transfer("DOVI", 5) is null && VideoTiers.Transfer("HDR10", 5) is null, "profile 5 can't be transcoded without a reshape");
Check(VideoTiers.Transfer("DOVI", 5, canReshape: true) == TierTransfer.Pq, "profile 5 becomes HDR10 with one");
Check(VideoTiers.NeedsReshape("DOVI", null) && VideoTiers.NeedsReshape("DOVIWithHDR10", 5) && !VideoTiers.NeedsReshape("DOVIWithHDR10", 8)
      && !VideoTiers.NeedsReshape("DOVIWithEL", 7), "only profile 5 (no base) needs its RPU applied");

// 3. Height validation and boxes.
Check(VideoTiers.IsTier(1440) && VideoTiers.IsTier(1080) && !VideoTiers.IsTier(720) && !VideoTiers.IsTier(2160), "only 1440 and 1080 are tiers");
Check(VideoTiers.BoxWidth(1440) == 2560 && VideoTiers.BoxWidth(1080) == 1920, "boxes are 16:9");
Check(VideoTiers.BitsPerSecond(1440) == 24_000_000 && VideoTiers.BitsPerSecond(1080) == 14_000_000, "24 and 14 Mbps");

// 4. Forced keyframes: every start from the run's first to the one after its last, a lead early.
var starts = new List<double> { 0, 1.001, 2.002, 5.505, 6.006, 10.01 };
var forced = VideoTiers.ForcedKeyframes(starts, 2, 3);
Check(forced.Count == 3 && Math.Abs(forced[0] - 1.994) < 1e-9 && Math.Abs(forced[1] - 5.497) < 1e-9 && Math.Abs(forced[2] - 5.998) < 1e-9,
    $"segments 2-3 force 2, 3 and 4, 8 ms early ({string.Join(",", forced)})");
Check(VideoTiers.ForcedKeyframes(starts, 4, 5).Count == 2, "a run to the last segment forces no time past the end");
Check(VideoTiers.ForcedKeyframes(starts, 0, 0)[0] == 0, "segment 0 is never forced before zero");
Check(VideoTiers.ForcedKeyframes(starts, 3, 3)[0] > starts[2], "nothing is listed before the run's own first segment");
Check(VideoTiers.KeyframeLeadSeconds < 1.0 / 60 / 2, "the lead is under half a 60 fps frame");

// 5. The encoder's arguments.
var x265 = VideoTiers.EncodeArguments(TierEncoder.X265, 1080, TierTransfer.Pq, forced);
string After(List<string> a, string flag) => a.IndexOf(flag) is var i && i >= 0 && i + 1 < a.Count ? a[i + 1] : "";
Check(After(x265, "-c:v") == "libx265" && After(x265, "-profile:v") == "main10" && After(x265, "-tag:v") == "hvc1", "x265: HEVC Main10, hvc1");
Check(After(x265, "-vf").StartsWith("scale=w=1920:h=1080:force_original_aspect_ratio=decrease", StringComparison.Ordinal)
      && After(x265, "-vf").EndsWith("format=yuv420p10le", StringComparison.Ordinal), "x265: scaled into 1920x1080, 10-bit");
Check(After(x265, "-force_key_frames") == "1.994,5.497,5.998", "the forced times, in film time, comma separated");
Check(After(x265, "-x265-params").Contains("scenecut=0") && After(x265, "-x265-params").Contains("open-gop=0")
      && After(x265, "-forced-idr") == "1" && After(x265, "-g") == "100000", "x265: no scene cuts, closed GOPs, forced IDRs, no keyint of its own");
Check(After(x265, "-dolbyvision") == "0", "x265: no Dolby Vision RPU");
Check(After(x265, "-color_trc") == "smpte2084" && After(x265, "-color_primaries") == "bt2020" && After(x265, "-colorspace") == "bt2020nc"
      && After(x265, "-x265-params").Contains("hdr10=1"), "PQ: BT.2020 PQ tags and HDR10 SEI");
Check(After(x265, "-b:v") == "14000000" && After(x265, "-fps_mode") == "passthrough" && x265.Contains("-an"), "14 Mbps, every frame at its time, no audio");
var vt = VideoTiers.EncodeArguments(TierEncoder.VideoToolbox, 1440, TierTransfer.Hlg, forced);
Check(After(vt, "-c:v") == "hevc_videotoolbox" && After(vt, "-profile:v") == "main10" && After(vt, "-vf").Contains("w=2560:h=1440")
      && After(vt, "-vf").EndsWith("format=p010le", StringComparison.Ordinal), "VideoToolbox: Main10 from P010 into 2560x1440");
Check(After(vt, "-color_trc") == "arib-std-b67" && After(vt, "-b:v") == "24000000", "HLG tags, 24 Mbps");
var sdr = VideoTiers.EncodeArguments(TierEncoder.X265, 1080, TierTransfer.Sdr, forced);
Check(!sdr.Contains("-color_trc") && !After(sdr, "-x265-params").Contains("hdr10"), "SDR: no HDR tags");

// 5b. Profile 5's RPU is applied before scaling, by the filter the server has.
var p5vt = VideoTiers.EncodeArguments(TierEncoder.VideoToolbox, 1080, TierTransfer.Pq, forced, TierReshape.VideoToolbox);
Check(After(p5vt, "-vf").StartsWith("tonemap_videotoolbox=format=p010:p=bt2020:t=smpte2084:m=bt2020:tonemap=none:apply_dovi=1,hwdownload,format=p010le,scale=", StringComparison.Ordinal)
      && After(p5vt, "-color_trc") == "smpte2084", "VideoToolbox reshape: RPU applied on the GPU, downloaded, then scaled, tagged HDR10");
Check(string.Join(" ", VideoTiers.InputArguments(TierReshape.VideoToolbox)) == "-hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld"
      && VideoTiers.InputArguments(TierReshape.Software).Count == 0 && VideoTiers.InputArguments(null).Count == 0, "only the VideoToolbox reshape decodes on the GPU");
var p5sw = VideoTiers.EncodeArguments(TierEncoder.X265, 1080, TierTransfer.Pq, forced, TierReshape.Software);
Check(After(p5sw, "-vf").StartsWith("tonemapx=p=bt2020:t=smpte2084:m=bt2020:tonemap=none:apply_dovi=1:format=yuv420p10le,scale=", StringComparison.Ordinal),
    "software reshape: tonemapx to PQ BT.2020 before scaling");
Check(!After(x265, "-vf").Contains("tonemap"), "no reshape: no tonemap filter");
const string jfFilters = " .S tonemap           V->V       Conversion to/from different dynamic ranges.\n .S tonemapx          V->V       SIMD optimized HDR to SDR tonemapping\n .. tonemap_videotoolbox V->V       Perform HDR to SDR conversion with Metal.\n";
const string stockFilters = " .S tonemap           V->V       Conversion to/from different dynamic ranges.\n";
Check(VideoTiers.PickReshape(jfFilters, TierEncoder.VideoToolbox) == TierReshape.VideoToolbox, "jellyfin-ffmpeg on a Mac: VideoToolbox");
Check(VideoTiers.PickReshape(jfFilters, TierEncoder.X265) == TierReshape.Software, "jellyfin-ffmpeg elsewhere: tonemapx");
Check(VideoTiers.PickReshape(stockFilters, TierEncoder.VideoToolbox) is null, "stock ffmpeg: none (tonemap alone can't apply an RPU)");

// 6. The encoder from ffmpeg's listing.
const string mac = " V....D libx265              libx265 H.265 / HEVC (codec hevc)\n V....D hevc_videotoolbox    VideoToolbox H.265 Encoder (codec hevc)\n";
const string linux = " V....D libx265              libx265 H.265 / HEVC (codec hevc)\n V....D hevc_nvenc           NVIDIA NVENC hevc encoder (codec hevc)\n";
Check(VideoTiers.PickEncoder(mac) == TierEncoder.VideoToolbox, "VideoToolbox when listed");
Check(VideoTiers.PickEncoder(linux) == TierEncoder.X265, "libx265 otherwise");
Check(VideoTiers.PickEncoder(" V....D libx264  libx264 H.264\n") is null, "neither: none");
Check(VideoTiers.PickEncoder(" V....D h264_videotoolbox  VideoToolbox H.264 Encoder\n") is null, "H.264 VideoToolbox doesn't count");

// 7. A run's init loses its empty edit (the film time it started at) and nothing else.
byte[] Box(string type, params byte[][] body)
{
    var content = body.SelectMany(b => b).ToArray();
    var box = new byte[8 + content.Length];
    System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(box, (uint)box.Length);
    System.Text.Encoding.Latin1.GetBytes(type).CopyTo(box, 4);
    content.CopyTo(box, 8);
    return box;
}
byte[] Be32(long v) { var b = new byte[4]; System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(b, (int)v); return b; }
byte[] Elst(params (long Duration, long MediaTime)[] entries) =>
    Box("elst", [[0, 0, 0, 0], Be32(entries.Length), .. entries.SelectMany(e => new[] { Be32(e.Duration), Be32(e.MediaTime), Be32(0x10000) })]);
byte[] Init(byte[] elst) => [.. Box("ftyp", [(byte)'i', (byte)'s', (byte)'o', (byte)'5']),
    .. Box("moov", Box("mvhd", new byte[100]), Box("trak", Box("tkhd", new byte[84]), Box("edts", elst), Box("mdia", new byte[16])))];
var withEmpty = Init(Elst((49000, -1), (0, 1024)));
var expectedInit = Init(Elst((0, 1024)));
var stripped = Fmp4.WithoutEmptyEdits(withEmpty);
Check(stripped.SequenceEqual(expectedInit), $"the empty edit goes, sizes patched ({withEmpty.Length} → {stripped.Length} bytes, expected {expectedInit.Length})");
Check(Fmp4.WithoutEmptyEdits(Init(Elst((19000, -1), (0, 1024)))).SequenceEqual(stripped), "two runs' inits come out the same");
var copyInit = Init(Elst((0, 672)));
Check(Fmp4.WithoutEmptyEdits(copyInit).SequenceEqual(copyInit), "a copy's init (no empty edit) is untouched");

Console.WriteLine($"{checks - fails}/{checks} checks passed");
return fails == 0 ? 0 : 1;
